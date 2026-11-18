# TailFeed notary witness key

Every TailFeed attestation is signed by this secp256k1 key (compressed):

```
03530b03f467022994514f72e0e5e98c6268c0dcc2d16568618a47480fba5ef2ae
```

- The private half lives in a secret store on the pusher host (`/root/.secrets/tailfeed_notary.env`, mode 0600) and is never committed, logged, or transmitted.
- The key rotates never by default. A rotation would be announced here and on the verify page before it takes effect.
- Receipts signed by any other key are not TailFeed receipts.

## Honest scope

The key is operated by TailFeed. A receipt proves the attested data came
from `api.robinhood.com` over a genuine TLS session — the signature proves
*who witnessed*, and today that witness is us. Independence (a third party
operating a notary key) is a known upgrade path; the cryptographic guarantee
of data provenance holds either way.

## Verifying a receipt's witness

```sh
./target/release/verify_proof <presentation file>
# checks the full cryptographic chain, including the notary signature,
# against the real public certificate roots — fully offline.
```
