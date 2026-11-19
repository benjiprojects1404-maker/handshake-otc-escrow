# Deploy and verify Handshake v4

**Deploy:** open **handshakeotc.fyi/deploy-v4/** with MetaMask on BlockDAG (1404): Connect → Dry run → Deploy, then
set the BDAG cap (read from v3) and hand ownership to the multisig. The page refuses to run if the deploy data's
hash isn't `0x8be341d5b03d267cc6a7c75a1071ad7d0df8bd66d5cc621c3ad7bcb114224005`.

Build: `HandshakeV4_standard_input.json` (source file name `HandshakeV4.sol`), solc **0.8.24**, optimizer **200**,
EVM **berlin**; no PUSH0 in the runtime. Expected gas about 1,874,000.

**Verify:** on the explorer choose *Standard JSON input*, upload `HandshakeV4_standard_input.json`, compiler 0.8.24,
contract `HandshakeV4`. Constructor arguments (ABI-encoded: WBDAG, fee recipient):

```
00000000000000000000000062ba5c4f067989a7f6644488c875bea69bfa1fba00000000000000000000000026bdba7b184df8b88965bed46aed6ea0e60ff940
```

Checked before release: these exact deploy bytes deployed on a local berlin chain (chain ID 1404), settings read back
correctly, a WBDAG-for-token trade filled with the fee paid and the contract left holding nothing, and ownership
moved to the multisig; the deploy page ran all three steps against that chain.

Remove `deploy-v4/` from the site once deployed.
