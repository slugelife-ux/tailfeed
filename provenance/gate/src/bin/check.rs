// Verify the gate: load attestation + secrets, build a presentation that
// reveals the full response body, verify it cryptographically, and print
// the attested price data. If this passes, the data provably came from a
// real TLS session with api.robinhood.com at the attested time.

use anyhow::Result;

use tlsn::attestation::{
    Attestation, CryptoProvider, Secrets,
    presentation::{Presentation, PresentationOutput},
};
use tlsn_formats::http::HttpTranscript;

#[tokio::main]
async fn main() -> Result<()> {
    let attestation: Attestation = bincode::deserialize(&std::fs::read("out/attestation.bin")?)?;
    let secrets: Secrets = bincode::deserialize(&std::fs::read("out/secrets.bin")?)?;

    let transcript = HttpTranscript::parse(secrets.transcript())?;

    let mut builder = secrets.transcript_proof_builder();

    let request = &transcript.requests[0];
    builder.reveal_sent(request.without_data())?;
    builder.reveal_sent(&request.request.target)?;
    for header in &request.headers {
        builder.reveal_sent(header.without_value())?;
    }

    let response = &transcript.responses[0];
    builder.reveal_recv(response.without_data())?;
    for header in &response.headers {
        builder.reveal_recv(header)?;
    }
    // Reveal the ENTIRE body: public price data, nothing to hide.
    builder.reveal_recv(response.body.as_ref().expect("body"))?;

    let transcript_proof = builder.build()?;

    let provider = CryptoProvider::default();
    let mut p_builder = attestation.presentation_builder(&provider);
    p_builder
        .identity_proof(secrets.identity_proof())
        .transcript_proof(transcript_proof);
    let presentation: Presentation = p_builder.build()?;

    std::fs::write("out/presentation.bin", bincode::serialize(&presentation)?)?;

    // Now verify the presentation against real public roots.
    let PresentationOutput {
        server_name,
        connection_info,
        transcript: p_transcript,
        ..
    } = presentation.verify(&provider).expect("presentation verifies");

    let server = server_name.expect("server name revealed");
    let time = chrono::DateTime::from_timestamp(connection_info.time as i64, 0)
        .expect("time")
        .to_rfc3339();

    let partial = p_transcript.expect("transcript");
    let received = partial
        .received_unsafe(partial.len_received())
        .expect("received data");
    let body = String::from_utf8_lossy(&received);

    println!("GATE_VERIFY_OK");
    println!("server: {server}");
    println!("session time: {time}");
    println!("attested response ({:>5} bytes):", body.len());
    println!("{body}");

    // Pull the quoted price out of the attested data (headers + body).
    if let Some(pos) = body.find('{') {
        let json = &body[pos..];
        let v: serde_json::Value = serde_json::from_str(json)?;
        let quotes = &v["quotes"][0];
        println!();
        println!("ATTESTED SYMBOL : {}", quotes["tokenSymbol"]);
        println!("ATTESTED BID    : {}", quotes["bid"]);
        println!("ATTESTED ASK    : {}", quotes["ask"]);
        println!("ATTESTED VOLUME : {}", quotes["dailyTradingVolume"]);
        println!("ATTESTED HALT   : {}", quotes["isTradingHalt"]);
        println!("ATTESTED GENERATED_AT: {}", quotes["generatedAt"]);
    }
    Ok(())
}
