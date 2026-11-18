// TailFeed provenance gate: notarize a real HTTPS session to
// api.robinhood.com/rhj/assets (TLS 1.2) and save attestation + secrets.
//
// In-process notary for the gate build (caveat registered: self-notarized).
// Everything else is real: real endpoint, real public CA roots, real MPC-TLS.

use std::{future::IntoFuture, time::Instant};

use anyhow::Result;
use futures::io::{AsyncReadExt as _, AsyncWriteExt as _};
use http_body_util::Empty;
use hyper::{Request, StatusCode, body::Bytes};
use hyper_util::rt::TokioIo;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_util::compat::{FuturesAsyncReadCompatExt as _, TokioAsyncReadCompatExt as _};
use tracing::info;

use tlsn::{
    Session,
    attestation::{
        Attestation, AttestationConfig, CryptoProvider,
        request::{Request as AttestationRequest, RequestConfig},
        signing::Secp256k1Signer,
    },
    config::{
        prove::ProveConfig, prover::ProverConfig, tls::TlsClientConfig,
        tls_commit::mpc::MpcTlsConfig, verifier::VerifierConfig,
    },
    connection::{CertBinding, ConnectionInfo, HandshakeData, ServerName, TranscriptLength},
    prover::ProverOutput,
    transcript::{ContentType, TranscriptCommitConfig},
    verifier::{VerifierCommitStart, VerifierOutput},
    webpki::CertificateDer,
};
use tlsn_formats::http::{DefaultHttpCommitter, HttpCommit, HttpTranscript};

const HOST: &str = "api.robinhood.com";
const URI_PATH: &str = "/rhj/prices/HIMS";
const USER_AGENT: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36";
// /rhj/prices/{SYM} responses are ~544 bytes; 16KB headroom. 2KB request.
const MAX_SENT: usize = 2048;
const MAX_RECV: usize = 16384;

fn real_root_store() -> tlsn::webpki::RootCertStore {
    // tlsn's webpki uses its own CertificateDer(Vec<u8>); native-certs returns
    // rustls-pki-types' — convert through the raw DER bytes.
    let roots: Vec<CertificateDer> = rustls_native_certs::load_native_certs()
        .expect("system roots")
        .into_iter()
        .map(|c| CertificateDer(c.as_ref().to_vec()))
        .collect();
    assert!(!roots.is_empty(), "no system roots found");
    tlsn::webpki::RootCertStore { roots }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    let t0 = Instant::now();

    // In-process notary over a duplex socket.
    let (notary_socket, prover_socket) = tokio::io::duplex(1 << 26);
    tokio::spawn(async move { notary(notary_socket).await.unwrap() });

    prover(prover_socket).await?;

    println!("GATE_PROVE_OK elapsed={:.1}s", t0.elapsed().as_secs_f64());
    Ok(())
}

async fn prover<S: AsyncWrite + AsyncRead + Send + Sync + Unpin + 'static>(socket: S) -> Result<()> {
    let session = Session::new(socket.compat());
    let (driver, mut handle) = session.split();
    let driver_task = tokio::spawn(driver);

    let prover = handle
        .new_prover(ProverConfig::builder().build()?)?
        .commit(
            MpcTlsConfig::builder()
                .max_sent_data(MAX_SENT)
                .max_recv_data(MAX_RECV)
                .build()?,
        )
        .await?;

    // Real TCP to the real server.
    let client_socket = tokio::net::TcpStream::connect((HOST, 443)).await?;
    client_socket.set_nodelay(true)?;

    let (tls_connection, prover) = prover
        .connect(
            TlsClientConfig::builder()
                .server_name(ServerName::Dns(HOST.try_into()?))
                .root_store(real_root_store())
                .build()?,
            client_socket.compat(),
        )?;
    let tls_connection = TokioIo::new(tls_connection.compat());

    let prover_task = tokio::spawn(prover.into_future());

    let (mut request_sender, connection) =
        hyper::client::conn::http1::handshake(tls_connection).await?;
    tokio::spawn(connection);

    let request = Request::builder()
        .uri(URI_PATH)
        .header("Host", HOST)
        .header("Accept", "*/*")
        // TLSNotary does not support compression.
        .header("Accept-Encoding", "identity")
        .header("Connection", "close")
        .header("User-Agent", USER_AGENT)
        .method("GET")
        .body(Empty::<Bytes>::new())?;

    info!("starting notarized session with {HOST}");
    let response = request_sender.send_request(request).await?;
    info!("response status: {}", response.status());
    assert!(response.status() == StatusCode::OK);

    let mut prover = prover_task.await??;

    // Commit to the whole HTTP transcript (all of it: public price data).
    let transcript = HttpTranscript::parse(prover.transcript())?;
    let mut builder = TranscriptCommitConfig::builder(prover.transcript());
    DefaultHttpCommitter::default().commit_transcript(&mut builder, &transcript)?;
    let transcript_commit = builder.build()?;

    let mut req_builder = RequestConfig::builder();
    req_builder.transcript_commit(transcript_commit);
    let request_config = req_builder.build()?;

    let mut prove_builder = ProveConfig::builder(prover.transcript());
    if let Some(config) = request_config.transcript_commit() {
        prove_builder.transcript_commit(config.clone());
    }
    let disclosure_config = prove_builder.build()?;

    let ProverOutput {
        transcript_commitments,
        transcript_secrets,
        ..
    } = prover.prove(&disclosure_config).await?;

    let prover_transcript = prover.transcript().clone();
    let tls_transcript = prover.tls_transcript().clone();
    prover.close().await?;

    let mut builder = AttestationRequest::builder(&request_config);
    builder
        .server_name(ServerName::Dns(HOST.try_into().unwrap()))
        .handshake_data(HandshakeData {
            certs: tls_transcript
                .server_cert_chain()
                .expect("server cert chain present")
                .to_vec(),
            sig: tls_transcript
                .server_signature()
                .expect("server signature present")
                .clone(),
            binding: tls_transcript.certificate_binding().clone(),
        })
        .transcript(prover_transcript)
        .transcript_commitments(transcript_secrets, transcript_commitments);

    let (request, secrets) = builder.build(&CryptoProvider::default())?;

    handle.close();
    let mut socket = driver_task.await??;

    // Send attestation request to the notary, receive the signed attestation.
    let request_bytes = bincode::serialize(&request)?;
    socket.write_all(&request_bytes).await?;
    socket.close().await?;
    let mut attestation_bytes = Vec::new();
    socket.read_to_end(&mut attestation_bytes).await?;
    let attestation: Attestation = bincode::deserialize(&attestation_bytes)?;

    let provider = CryptoProvider::default();
    request.validate(&attestation, &provider)?;

    let out = std::path::Path::new("out");
    tokio::fs::create_dir_all(out).await?;
    tokio::fs::write(out.join("attestation.bin"), bincode::serialize(&attestation)?).await?;
    tokio::fs::write(out.join("secrets.bin"), bincode::serialize(&secrets)?).await?;

    let attestation_len = bincode::serialize(&attestation)?.len();
    println!("attestation saved: out/attestation.bin ({attestation_len} bytes)");
    println!("secrets saved: out/secrets.bin");
    Ok(())
}

async fn notary<S: AsyncWrite + AsyncRead + Send + Sync + Unpin + 'static>(socket: S) -> Result<()> {
    let session = Session::new(socket.compat());
    let (driver, mut handle) = session.split();
    let driver_task = tokio::spawn(driver);

    // The notary also verifies the server against real public roots.
    let verifier_config = VerifierConfig::builder().root_store(real_root_store()).build()?;

    let verifier = match handle.new_verifier(verifier_config)?.commit().await? {
        VerifierCommitStart::Mpc(verifier) => verifier.accept().await?.run().await?,
        VerifierCommitStart::Proxy(verifier) => {
            verifier.reject(Some("expecting MPC-TLS")).await?;
            return Err(anyhow::anyhow!("protocol configuration rejected"));
        }
    };

    let (
        VerifierOutput {
            transcript_commitments,
            ..
        },
        verifier,
    ) = verifier.verify().await?.accept().await?;

    let tls_transcript = verifier.tls_transcript().clone();
    verifier.close().await?;

    let sent_len = tls_transcript
        .sent()
        .iter()
        .filter_map(|record| match record.typ {
            ContentType::ApplicationData => Some(record.ciphertext.len()),
            _ => None,
        })
        .sum::<usize>();
    let recv_len = tls_transcript
        .recv()
        .iter()
        .filter_map(|record| match record.typ {
            ContentType::ApplicationData => Some(record.ciphertext.len()),
            _ => None,
        })
        .sum::<usize>();

    // Close the session and wait for the driver, reclaiming the socket.
    handle.close();
    let mut socket = driver_task.await??;

    // Receive attestation request from the prover.
    let mut request_bytes = Vec::new();
    socket.read_to_end(&mut request_bytes).await?;
    let request: AttestationRequest = bincode::deserialize(&request_bytes)?;

    // Gate-build signing key (self-notarized caveat registered).
    let signing_key = k256::ecdsa::SigningKey::from_bytes(&[1u8; 32].into())?;
    let signer = Box::new(Secp256k1Signer::new(&signing_key.to_bytes())?);
    let mut provider = CryptoProvider::default();
    provider.signer.set_signer(signer);

    let mut att_config_builder = AttestationConfig::builder();
    att_config_builder.supported_signature_algs(Vec::from_iter(provider.signer.supported_algs()));
    let att_config = att_config_builder.build()?;

    let CertBinding::V1_2(binding) = tls_transcript.certificate_binding() else {
        panic!("unsupported cert binding version");
    };
    let mut builder = Attestation::builder(&att_config).accept_request(request)?;
    builder
        .connection_info(ConnectionInfo {
            time: tls_transcript.time(),
            version: tls_transcript.version(),
            transcript_length: TranscriptLength {
                sent: sent_len as u32,
                received: recv_len as u32,
            },
        })
        .server_ephemeral_key(binding.server_ephemeral_key.clone())
        .transcript_commitments(transcript_commitments);

    let attestation = builder.build(&provider)?;

    // Send the attestation to the prover.
    let attestation_bytes = bincode::serialize(&attestation)?;
    socket.write_all(&attestation_bytes).await?;
    socket.close().await?;

    Ok(())
}
