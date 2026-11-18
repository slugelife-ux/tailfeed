// Verify any TailFeed provenance presentation: load the file, verify it
// cryptographically against real public roots, print the attested data.
// Usage: verify_proof <presentation.bin>

use anyhow::Result;

use tlsn::attestation::{
    CryptoProvider,
    presentation::{Presentation, PresentationOutput},
};

#[tokio::main]
async fn main() -> Result<()> {
    let path = std::env::args()
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("usage: verify_proof <presentation.bin>"))?;
    let presentation: Presentation =
        bincode::deserialize(&std::fs::read(&path)?)?;

    let provider = CryptoProvider::default();

    let PresentationOutput {
        server_name,
        connection_info,
        transcript: p_transcript,
        ..
    } = presentation
        .verify(&provider)
        .map_err(|e| anyhow::anyhow!("VERIFICATION FAILED: {e:?}"))?;

    let server = server_name.expect("server name revealed");
    let time = chrono::DateTime::from_timestamp(connection_info.time as i64, 0)
        .expect("time")
        .to_rfc3339();

    let partial = p_transcript.expect("transcript");
    let received = partial
        .received_unsafe(partial.len_received())
        .expect("received data");
    let body = String::from_utf8_lossy(&received);

    println!("VERIFIED: data below provably came from {server} at {time}");
    if let Some(pos) = body.find('{') {
        let json = &body[pos..];
        let v: serde_json::Value = serde_json::from_str(json)?;
        let q = &v["quotes"][0];
        println!(
            "{}: bid {} / ask {}  vol {}  halt {}  generated {}",
            q["tokenSymbol"],
            q["bid"],
            q["ask"],
            q["dailyTradingVolume"],
            q["isTradingHalt"],
            q["generatedAt"]
        );
    }
    Ok(())
}
