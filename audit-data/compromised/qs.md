## CheakCode#1

**Generate Address**

- `vm.makeAddr(string)`

  1. deterministically generate an address from a string
  2. no private key
  3. can't used for signing (ECDSA)

- `vm.makeAddrAndKey(string)`

  1. private key and address are cryptographically linked
  2. can be used with `vm.sign` -> off-chain signature + on-chain verification

**Signatures and Address Recovery**

- `vm.sign(uint256, bytes)`
  1.  sign a digest using specific private key

```js
(bytes32 r, bytes32 s, uint8 v) = vm.sign(privateKey, digest);
```

- `vm.addr(uint256)`

  1. derived an address from a private key
