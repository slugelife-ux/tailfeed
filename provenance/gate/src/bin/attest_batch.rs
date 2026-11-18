// Batch provenance: N parallel notarized TLS sessions with
// api.robinhood.com, one price request per session (~5s each).
// One MPC session per request avoids server keep-alive timeouts:
// MPC-TLS is too slow for multi-request sessions against real CDNs.
//
// Outputs (per batch run, timestamped) under the out dir:
//   attest-<ts>-<SYM>.bin       per-symbol attestation (the receipt)
//   presentation-<ts>-<SYM>.bin per-symbol full-reveal presentation
//   manifest-<ts>.json          all prices + merkle root + batch root
//
// Merkle leaf: keccak256(symbol_ascii ++ u256_be(answer) ++ u256_be(gen_at))
// Batch root: keccak over sorted per-symbol attestation sha256 digests.

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
const USER_AGENT: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36";
const MAX_SENT: usize = 2048;
const MAX_RECV: usize = 16384;
const CONCURRENCY: usize = 6;

fn real_root_store() -> tlsn::webpki::RootCertStore {
    let roots: Vec<CertificateDer> = rustls_native_certs::load_native_certs()
        .expect("system roots")
        .into_iter()
        .map(|c| CertificateDer(c.as_ref().to_vec()))
        .collect();
    assert!(!roots.is_empty(), "no system roots found");
    tlsn::webpki::RootCertStore { roots }
}

fn keccak256(data: &[u8]) -> [u8; 32] {
    use tiny_keccak::{Hasher, Keccak};
    let mut k = Keccak::v256();
    k.update(data);
    let mut out = [0u8; 32];
    k.finalize(&mut out);
    out
}

fn be256(v: u128) -> [u8; 32] {
    let mut b = [0u8; 32];
    b[32 - 16..].copy_from_slice(&v.to_be_bytes());
    b
}

#[derive(serde::Serialize, Clone)]
struct FeedRow {
    id: u64,
    symbol: String,
    bid: String,
    ask: String,
    multiplier: f64,
    answer: u64,
    generated_at: String,
    halted: bool,
    leaf: String,
    attestation: String,
    attestation_sha256: String,
    presentation: String,
    prove_seconds: f64,
}

#[derive(serde::Serialize)]
struct Manifest {
    source: String,
    batch_time: u64,
    feeds: Vec<FeedRow>,
    merkle_root: String,
    batch_root: String,
}

struct Sym {
    id: u64,
    symbol: String,
    multiplier: f64,
}

async fn attest_one(sym: &Sym, out_dir: &std::path::Path, batch_ts: u64) -> Result<FeedRow> {
    let t0 = Instant::now();

    let (notary_socket, prover_socket) = tokio::io::duplex(1 << 24);
    tokio::spawn(async move {
        if let Err(e) = notary(notary_socket).await {
            tracing::warn!("notary: {e}");
        }
    });

    // ---- prover: single request session ----
    let session = Session::new(prover_socket.compat());
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
        .uri(format!("/rhj/prices/{}", sym.symbol))
        .header("Host", HOST)
        .header("Accept", "application/json")
        .header("Accept-Encoding", "identity")
        .header("Connection", "close")
        .header("User-Agent", USER_AGENT)
        .method("GET")
        .body(Empty::<Bytes>::new())?;
    let response = request_sender.send_request(request).await?;
    assert!(response.status() == StatusCode::OK, "non-200 for {}", sym.symbol);

    let mut prover = prover_task.await??;

    // HttpTranscript is !Send: scope the commit so it drops before the
    // prove await, then re-parse from the cloned transcript afterwards.
    let transcript_commit = {
        let transcript = HttpTranscript::parse(prover.transcript())?;
        let mut builder = TranscriptCommitConfig::builder(prover.transcript());
        DefaultHttpCommitter::default().commit_transcript(&mut builder, &transcript)?;
        builder.build()?
    };

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

    let request_bytes = bincode::serialize(&request)?;
    socket.write_all(&request_bytes).await?;
    socket.close().await?;
    let mut attestation_bytes = Vec::new();
    socket.read_to_end(&mut attestation_bytes).await?;
    let attestation: Attestation = bincode::deserialize(&attestation_bytes)?;

    let provider = CryptoProvider::default();
    request.validate(&attestation, &provider)?;
    let prove_secs = t0.elapsed().as_secs_f64();

    // ---- extract the attested price (re-parse after all awaits) ----
    let transcript = HttpTranscript::parse(secrets.transcript())?;
    let resp = &transcript.responses[0];
    let body = resp.body.as_ref().expect("body");
    let data = body.content_data();
    let v: serde_json::Value = serde_json::from_slice(data.as_ref())?;
    let q = &v["quotes"][0];
    let bid = q["bid"].as_str().unwrap_or("0").to_string();
    let ask = q["ask"].as_str().unwrap_or("0").to_string();
    let gen_str = q["generatedAt"].as_str().unwrap_or("").to_string();
    let halted = q["isTradingHalt"].as_bool().unwrap_or(false);
    let bid_f: f64 = bid.parse().unwrap_or(0.0);
    let ask_f: f64 = ask.parse().unwrap_or(0.0);
    let mid = (bid_f + ask_f) / 2.0;
    let answer = ((mid * sym.multiplier * 1e8) + 0.5).floor() as u64;
    let gen_ts = chrono::DateTime::parse_from_rfc3339(&gen_str)
        .map(|d| d.timestamp() as u128)
        .unwrap_or(0);
    let mut leaf_input = sym.symbol.as_bytes().to_vec();
    leaf_input.extend_from_slice(&be256(answer as u128));
    leaf_input.extend_from_slice(&be256(gen_ts));
    let leaf = keccak256(&leaf_input);

    // ---- full-reveal presentation ----
    let mut p_builder = secrets.transcript_proof_builder();
    let req = &transcript.requests[0];
    p_builder.reveal_sent(req.without_data())?;
    p_builder.reveal_sent(&req.request.target)?;
    for h in &req.headers {
        p_builder.reveal_sent(h.without_value())?;
    }
    p_builder.reveal_recv(resp.without_data())?;
    for h in &resp.headers {
        p_builder.reveal_recv(h)?;
    }
    p_builder.reveal_recv(resp.body.as_ref().expect("body"))?;
    let transcript_proof = p_builder.build()?;

    let provider = CryptoProvider::default();
    let mut ab = attestation.presentation_builder(&provider);
    ab.identity_proof(secrets.identity_proof())
        .transcript_proof(transcript_proof);
    let presentation = ab.build()?;

    // ---- write per-symbol artifacts ----
    let attest_path = out_dir.join(format!("attest-{batch_ts}-{}.bin", sym.symbol));
    let pres_path = out_dir.join(format!("presentation-{batch_ts}-{}.bin", sym.symbol));
    std::fs::write(&attest_path, &attestation_bytes)?;
    std::fs::write(&pres_path, bincode::serialize(&presentation)?)?;

    use sha2::Digest as _;
    let mut hasher = sha2::Sha256::new();
    hasher.update(&attestation_bytes);
    let attest_sha = hex::encode(hasher.finalize());

    Ok(FeedRow {
        id: sym.id,
        symbol: sym.symbol.clone(),
        bid,
        ask,
        multiplier: sym.multiplier,
        answer,
        generated_at: gen_str,
        halted,
        leaf: hex::encode(leaf),
        attestation: attest_path.file_name().unwrap().to_string_lossy().into_owned(),
        attestation_sha256: attest_sha,
        presentation: pres_path.file_name().unwrap().to_string_lossy().into_owned(),
        prove_seconds: prove_secs,
    })
}

async fn notary<S: AsyncWrite + AsyncRead + Send + Sync + Unpin + 'static>(socket: S) -> Result<()> {
    let session = Session::new(socket.compat());
    let (driver, mut handle) = session.split();
    let driver_task = tokio::spawn(driver);

    let verifier_config = VerifierConfig::builder().root_store(real_root_store()).build()?;

    let verifier = match handle.new_verifier(verifier_config)?.commit().await? {
        VerifierCommitStart::Mpc(verifier) => verifier.accept().await?.run().await?,
        VerifierCommitStart::Proxy(verifier) => {
            verifier.reject(Some("expecting MPC-TLS")).await?;
            return Err(anyhow::anyhow!("protocol configuration rejected"));
        }
    };

    let (VerifierOutput { transcript_commitments, .. }, verifier) = verifier.verify().await?.accept().await?;
    let tls_transcript = verifier.tls_transcript().clone();
    verifier.close().await?;

    let sent_len = tls_transcript
        .sent()
        .iter()
        .filter_map(|r| match r.typ {
            ContentType::ApplicationData => Some(r.ciphertext.len()),
            _ => None,
        })
        .sum::<usize>();
    let recv_len = tls_transcript
        .recv()
        .iter()
        .filter_map(|r| match r.typ {
            ContentType::ApplicationData => Some(r.ciphertext.len()),
            _ => None,
        })
        .sum::<usize>();

    handle.close();
    let mut socket = driver_task.await??;

    let mut request_bytes = Vec::new();
    socket.read_to_end(&mut request_bytes).await?;
    let request: AttestationRequest = bincode::deserialize(&request_bytes)?;

    let key_hex = std::env::var("TAILFEED_NOTARY_KEY")
        .expect("TAILFEED_NOTARY_KEY (hex) must be set; see /root/.secrets/tailfeed_notary.env");
    let key_bytes = hex::decode(key_hex.trim()).expect("notary key must be hex");
    assert_eq!(key_bytes.len(), 32, "notary key must be 32 bytes");
    let arr: [u8; 32] = key_bytes.try_into().expect("notary key must be 32 bytes");
    let signing_key = k256::ecdsa::SigningKey::from_bytes(&arr.into())?;
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

    let attestation_bytes = bincode::serialize(&attestation)?;
    socket.write_all(&attestation_bytes).await?;
    socket.close().await?;

    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();

    let feeds_path = std::env::args().nth(1)
        .unwrap_or_else(|| "/root/onchain-studio/ops/testnet_feeds.json".into());
    let out_dir = std::env::args().nth(2).unwrap_or_else(|| "proofs".into());

    let feeds: Vec<serde_json::Value> = serde_json::from_str(&std::fs::read_to_string(&feeds_path)?)?;
    let symbols: Vec<Sym> = feeds
        .iter()
        .map(|f| Sym {
            id: f["id"].as_u64().unwrap_or(0),
            symbol: f["symbol"].as_str().unwrap_or("").to_string(),
            multiplier: f.get("multiplier").and_then(|m| m.as_f64()).unwrap_or(1.0),
        })
        .collect();
    assert!(!symbols.is_empty(), "no feeds in manifest");
    info!("batch: {} symbols, concurrency {CONCURRENCY}", symbols.len());

    let t0 = Instant::now();
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs();

    let dir = std::path::Path::new(&out_dir);
    std::fs::create_dir_all(dir)?;

    // parallel single-symbol sessions, throttled
    let sem = std::sync::Arc::new(tokio::sync::Semaphore::new(CONCURRENCY));
    let mut handles = Vec::new();
    for sym in &symbols {
        let permit = sem.clone().acquire_owned().await?;
        let sym = Sym { id: sym.id, symbol: sym.symbol.clone(), multiplier: sym.multiplier };
        let dir = dir.to_path_buf();
        handles.push(tokio::spawn(async move {
            let _p = permit;
            attest_one(&sym, &dir, ts).await
        }));
    }

    let mut rows: Vec<FeedRow> = Vec::new();
    let mut failures: Vec<String> = Vec::new();
    for h in handles {
        match h.await {
            Ok(Ok(row)) => rows.push(row),
            Ok(Err(e)) => failures.push(format!("{e}")),
            Err(e) => failures.push(format!("join: {e}")),
        }
    }

    // merkle root over price leaves
    let mut layer: Vec<[u8; 32]> = rows
        .iter()
        .map(|r| {
            let mut l = [0u8; 32];
            hex::decode_to_slice(&r.leaf, &mut l).expect("leaf hex");
            l
        })
        .collect();
    while layer.len() > 1 {
        if layer.len() % 2 == 1 {
            let last = *layer.last().unwrap();
            layer.push(last);
        }
        layer = layer
            .chunks(2)
            .map(|pair| {
                let mut buf = pair[0].to_vec();
                buf.extend_from_slice(&pair[1]);
                keccak256(&buf)
            })
            .collect();
    }
    let merkle_root = if layer.is_empty() { "00".repeat(32) } else { hex::encode(layer[0]) };

    // batch root over sorted attestation digests
    let mut digests: Vec<[u8; 32]> = rows
        .iter()
        .map(|r| {
            let mut d = [0u8; 32];
            hex::decode_to_slice(&r.attestation_sha256, &mut d).expect("sha hex");
            d
        })
        .collect();
    digests.sort();
    let mut buf = Vec::new();
    for d in &digests {
        buf.extend_from_slice(d);
    }
    let batch_root = keccak256(&buf);

    let ok = rows.len();
    let manifest = Manifest {
        source: format!("https://{HOST}/rhj/prices/{{symbol}}"),
        batch_time: ts,
        feeds: rows,
        merkle_root,
        batch_root: format!("0x{}", hex::encode(batch_root)),
    };
    let manifest_path = dir.join(format!("manifest-{ts}.json"));
    std::fs::write(&manifest_path, serde_json::to_vec_pretty(&manifest)?)?;

    println!("BATCH_ATTEST_OK");
    println!("attested: {ok}/{} in {:.1}s wall", symbols.len(), t0.elapsed().as_secs_f64());
    if !failures.is_empty() {
        println!("failures: {} (first: {})", failures.len(), failures[0]);
    }
    println!("merkle_root: 0x{}", manifest.merkle_root);
    println!("batch_root:  {}", manifest.batch_root);
    println!("manifest: {}", manifest_path.display());
    if ok == 0 {
        return Err(anyhow::anyhow!("all attestations failed"));
    }
    Ok(())
}
