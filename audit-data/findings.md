### [H-1] Critical Logic Error in `Game::claimThrone()` renders entire contract unusable and permanently locks all funds

**Description** The `Game::claimThrone()` function contains a fatal logic error in its access control check.

The require statement

```js
require(msg.sender ==
  currentKing, "Game: You are already the king. No need to re-claim.");
```

should use `!=` instead of `==`. Since currentKing is initialized to `address(0)` and msg.sender can never be `address(0), this condition will always fail, making the function permanently uncallable.

This creates a **cascading** failure that breaks the entire contract:

- No one can ever claim the throne
- `declareWinner()` can never be called `(requires currentKing != address(0))`
- `resetGame()` can never be called (`requires gameEnded = true` from `declareWinner()`)
- The contract becomes a fund sink with no recovery mechanism

**Impact**

1. Complete loss of functionality
2. Permanent fund locking
3. Contract DOA (Dead on arrival)
4. No recover possible - even the owner cannot reset or fix the contract state

**Proof of Concepts**

A user with balance more than `claimFee` needed to `claimThone()` is unable to claim throne.

```js
function test_claim_throne() external {
        uint256 amountNeededToClainThrone = game.claimFee();
        uint256 player1Balance = player1.balance;
        assertGt(player1Balance, amountNeededToClainThrone);
        vm.startPrank(player1);
        vm.expectRevert("Game: You are already the king. No need to re-claim.");
        game.claimThrone{value: INITIAL_CLAIM_FEE}();
        vm.stopPrank();
    }
```

**Recommended mitigation** Change `==` to `!=` in the require statement of access control

```diff
-        require(msg.sender == currentKing, "Game: You are already the king. No need to re-claim.");
+        require(msg.sender != currentKing, "Game: You are already the king. No need to re-claim.");
```

### [M-1] MEV Front-Running Attack Enables Griefing and Potential Theft Through Grace Period Manipulation by superseding `declareWinner` with `claimThrone`

**Note:** _This vulnerability assumes the critical logic error in `claimThrone()` is fixed (changing `require(msg.sender == currentKing`) to `require(msg.sender != currentKing)`) to make the contract functional._

**Description** An attacker can monitor the mempool for `declareWinner()` transactions and front-run them with `claimThrone()` calls to reset the grace period timer. This attack prevents legitimate winners from claiming their prize and forces additional waiting periods. If no other players intervene during the new grace period, the attacker can eventually claim the entire pot themselves.

The attack exploits the fact that `claimThrone()` updates `lastClaimTime = block.timestamp`, which resets the grace period countdown and causes the original `declareWinner()` transaction to revert with **Grace period has not expired yet.**

_Prerequisites_

- The fundamental `claimThrone()` logic error must be fixed for the contract to function
- Game must be in progress with an active currentKing
- Grace period must be near expiration

**Impact**

1. Legitimate winners can not claim victory when the grace period should have expired.
2. Forcing all players to wait additional grace periods, wasting time and gas.
3. If the attacker successfully prevents others from claiming during the new grace period, they can steal the entire accumulated pot
4. Repeated attacks can theoretically extend the game indefinitely

**Proof of Concepts**

1. Three players played to claim thone. 3rd player being the last one becomes the potential legitimate winner.
2. After passing of the grace period, some one tries to call the `declareWinner` function.
3. However, a malicious attack sees this transaction in the mempool and supersedes this with another `claimThrone` transaction.
4. Hence manipulating the grace period and forcing players to wait for additional grace period.

```js
function test_FrontRun_declareWinner_To_Cause_Grief() external {
        vm.prank(player1);
        game.claimThrone{value: INITIAL_CLAIM_FEE}();

        uint256 claimFee = game.claimFee();
        vm.prank(player2);
        game.claimThrone{value: claimFee}();

        claimFee = game.claimFee();
        vm.prank(player3);
        game.claimThrone{value: claimFee}();

        address currentKing = game.currentKing();
        assertEq(currentKing, player3);

        uint256 newTime = block.timestamp + game.getRemainingTime();

        vm.warp(newTime + 1);

        //declare winner
        // game.declareWinner();
        // uint256 winnerPendings = game.pendingWinnings(player3);
        // assertGt(winnerPendings, 0); //3.144e17

        //attacker supersedes this above transaction with claimThrone
        claimFee = game.claimFee();
        vm.prank(maliciousActor);
        game.claimThrone{value: claimFee}();
        currentKing = game.currentKing();
        assertEq(currentKing, maliciousActor);

        vm.expectRevert("Game: Grace period has not expired yet.");
        game.declareWinner();
        uint256 winnerPendings = game.pendingWinnings(player3);
        assertEq(winnerPendings, 0);

        //attacker is required for grace period to pass meanwhile there is a chance for others to claim throne, hence causing more delays

        newTime = block.timestamp + game.getRemainingTime();
        vm.warp(newTime + 1);

        //If no one claims the throne in between then attacker becomes the kind
        game.declareWinner();
        winnerPendings = game.pendingWinnings(maliciousActor);
        assertGt(winnerPendings, 0); //4.408e17
        assertEq(currentKing, maliciousActor);

    }
```

**Recommended mitigation** Implement a commit-reveal scheme or time-lock mechanism to prevent last-second interventions. Something like this -

```js
uint256 public claimCutoffPeriod = 1 hours; // No claims allowed in final hour

function claimThrone() external payable gameNotEnded nonReentrant {
    require(
        block.timestamp < lastClaimTime + gracePeriod - claimCutoffPeriod,
        "Game: Claims disabled in final period before winner declaration"
    );
    // ... rest of function
}

```

### [L-1] No index variable defined for important event `Game::GameReset`

**Description** The `GameReset` event lacks **indexed** parameters, which significantly reduces its utility for off-chain applications and monitoring systems. Currently, the event is defined as:

```js
    event GameReset(uint256 newRound, uint256 timestamp);
```

**Impact** Off-chain applications cannot efficiently filter events by specific game rounds, causing difficulty in tracking.

**Recommended mitigation**

```diff
-        event GameReset(uint256 newRound, uint256 timestamp);
+        event GameReset(uint256 indexed newRound, uint256 timestamp);

```

### [L-2] CEI Pattern Violation in withdrawWinnings()

**Description** The function violates Checks-Effects-Interactions (CEI) pattern but is protected by nonReentrant modifier.

```js
function withdrawWinnings() external nonReentrant {
        uint256 amount = pendingWinnings[msg.sender];
        require(amount > 0, "Game: No winnings to withdraw.");

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Game: Failed to withdraw winnings.");

        pendingWinnings[msg.sender] = 0;

        emit WinningsWithdrawn(msg.sender, amount);
    }
```

**Recommended mitigation**
Follow CEI pattern for code clarity and defense-in-depth.

```diff
function withdrawWinnings() external nonReentrant {
        uint256 amount = pendingWinnings[msg.sender];
        require(amount > 0, "Game: No winnings to withdraw.");
+       pendingWinnings[msg.sender] = 0;
+       emit WinningsWithdrawn(msg.sender, amount);

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Game: Failed to withdraw winnings.");

-        pendingWinnings[msg.sender] = 0;
-        emit WinningsWithdrawn(msg.sender, amount);
    }

```

### [I-1] `Game::initialGracePeriod` should be declared as immutable

**Description** The `Game::initialGracePeriod` is only assigned once during contract deployment in the `constructor` and is never modified afterward.

However, it is currently declared as a regular state variable, which consumes a storage slot and incurs higher gas costs for reads. Since this value remains constant throughout the contract's lifetime, it should be declared as **immutable** to optimize gas usage.

```solidity
uint256 public initialGracePeriod;
```

**Impact** Unnecessary wastage of storage slot, which could be avoided.

**Recommended mitigation**

```diff
-        uint256 public initialGracePeriod;
+        uint256 public immutable i_initialGracePeriod;
```

### [G-1] `feeIncreasePercentage` and `platformFeePercentage` percentage variables should use `uint8` instead of `uint256`

**Description** The contract uses `uint256` for percentage values that are expected to be `≤ 100`. Both `feeIncreasePercentage` and `platformFeePercentage` represent percentage values that realistically will never exceed 100 **(representing 0-100%)**. Using `uint256` (32 bytes) for values that can be stored in `uint8` (1 byte) wastes storage slots and increases gas costs.

```js
uint256 public feeIncreasePercentage; // Expected ≤ 100, could be uint8
uint256 public platformFeePercentage; // Expected ≤ 100, could be uint8
```

Each `uint256` consumes a full `32-byte` storage slot, while `uint8` values can be packed together in a single slot when declared consecutively.

**Impact** Two full storage slots (64 bytes) used when one slot (32 bytes) could suffice

**Recommended mitigation**

```diff
-       uint256 public feeIncreasePercentage;
-       uint256 public platformFeePercentage;

+       uint8 public feeIncreasePercentage;
+       uint8 public platformFeePercentage;

```

### [G-2] `getRemainingTime` and `getContractBalance` functions should be declared as external

**Description** Functions not called within the contract should be marked as external. External functions consume less gas as compared to public functions.

**Impact** Expensive to call public functions.

**Recommended mitigation**

```diff
-       function getRemainingTime() public view returns (uint256) {
+       function getRemainingTime() external view returns (uint256) {
                if (gameEnded) {
                    return 0; // Game has ended, no remaining time
                }
                uint256 endTime = lastClaimTime + gracePeriod;
                if (block.timestamp >= endTime) {
                    return 0; // Grace period has expired
                }
                return endTime - block.timestamp;
            }

-       function getContractBalance() public view returns (uint256) {
+       function getContractBalance() external view returns (uint256) {
                return address(this).balance;
            }

```
