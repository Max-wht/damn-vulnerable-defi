### [H-3] `AuthorizedExecutor::execute()` Uses a Hard-Coded Calldata Offset for Selector Extraction (ABI Smuggling)

**Description:**

`AuthorizedExecutor.execute()` reads the selector for permission checks from a fixed calldata position:

```solidity
uint256 calldataOffset = 4 + 32 * 3; // 0x64
assembly {
    selector := calldataload(calldataOffset)
}
```

This assumes `actionData` always starts at `0x64`, which is only true for canonical ABI encoding with a specific dynamic offset.  
However, calldata can be crafted with a non-canonical offset for `actionData` (for example `0x80`) while still being accepted by Solidity decoding.

As a result, an attacker can:

1. Place a **fake selector** at `0x64` (e.g., `withdraw`) to satisfy `permissions[getActionId(selector, msg.sender, target)]`.
2. Place the **real actionData** at the attacker-controlled offset (e.g., `0x80`) with a different selector (e.g., `sweepFunds`).
3. Pass authorization with one function but execute another function.

In this challenge, the player is only authorized for `withdraw`, but can execute `sweepFunds` and drain the vault.

**Impact:**

Authorization bypass of the vault's permission model.  
An attacker with permission for one action can execute a different privileged action, enabling full token theft (`sweepFunds`) and bypassing withdrawal limits/waiting-period protections.

**Proof of Concept (from test):**

The exploit in `test/abi-smuggling/ABISmuggling.t.sol` builds malicious calldata where:

- `0x64` contains `withdraw` selector (`0xd9caed12`) for the permission check.
- Actual `actionData` points to a later offset and contains `sweepFunds` selector (`0x85fb709d`).

This passes permission validation and transfers all vault funds to `recovery`.

**Recommended Remediation:**

Never derive the selector from a hard-coded calldata index.  
Extract it from the decoded `actionData` slice itself:

```solidity
require(actionData.length >= 4, "Invalid actionData");
bytes4 selector = bytes4(actionData[0:4]);
```

or, equivalently, using the actual calldata pointer:

```solidity
bytes4 selector;
assembly {
    selector := calldataload(actionData.offset)
}
```

This ensures the checked selector always matches the bytes that will actually be executed.
