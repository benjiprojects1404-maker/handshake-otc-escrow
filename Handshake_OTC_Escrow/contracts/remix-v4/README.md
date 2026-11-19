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

## Deployed

| | |
|---|---|
| HandshakeV4 | `0x7E13D7dC4B35a5a1681Ecb4237580A7d90aeAffe` (chain 1404, 19 Nov 2026, from `0xca83…99b5`, 1,873,838 gas, the same as the local test) |
| Deploy tx | `0x6379084aba2516ad9fce813727624e1e400a187c38c563b1515ba9893a341d91` |
| BDAG cap | 1,000,000 BDAG per offer (same as v3), tx `0x1dcb7eabf8bfc0885abb6fc2fe5ec0c24ce1e5ecf3818b570648ee95b866e659` |
| Owner | Reef admin multisig `0x4E2401bFD24c66166fABF9Cc5cD5B6B2c5c860fc`, tx `0x3cba5108753c4c9eaf6bf344ea21f82b609e00e0e93dcbdb4d1195d5c5f5d248` |
