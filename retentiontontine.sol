// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ERC20 Tontine (Partial Withdrawals + Multi-Deposit)
 * @notice
 *  - Multiple deposits allowed during enrollment.
 *  - Partial withdrawals: user picks an `amount` <= deposited.
 *  - On withdrawal (partial or full), user first receives feePool share
 *    proportional to (amount / totalDeposits) *before* applying any penalty.
 *  - The payout then uses the same phase rules as before:
 *      * Before enrollmentEnd: full payout on the withdrawn slice (no penalty)
 *      * Between enrollmentEnd and payoutTime:
 *           - If this withdrawal empties the pool (i.e., user becomes last staker and
 *             takes everything), NO penalty on the withdrawn slice.
 *           - Otherwise 20% penalty on the withdrawn slice goes to feePool.
 *      * After payoutTime: full payout (no penalty)
 */

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amt) external returns (bool);
    function transferFrom(address from, address to, uint256 amt) external returns (bool);
    function decimals() external view returns (uint8);
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;
    modifier nonReentrant() {
        require(_status == _NOT_ENTERED, "ReentrancyGuard: reentrant");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract ERC20Tontine is ReentrancyGuard {
    struct Account {
        uint256 entitlement; // claimable token amount (stake + accrued fee shares)
        uint256 deposited;   // active stake
    }

    IERC20 public immutable token;

    mapping(address => Account) public accounts;

    uint256 public immutable enrollmentEnd; // end of deposit window
    uint256 public immutable payoutTime;    // time after which full withdrawals are allowed

    uint256 public feePool;        // accumulated mid-game penalties to distribute
    uint256 public totalDeposits;  // sum of all active deposits

    event Deposited(address indexed user, uint256 amount);
    event PartialWithdrawn(address indexed user, uint256 amountRequested, uint256 paidOut, uint256 penaltyToPool);
    event WithdrawnAll(address indexed user, uint256 paidOut, uint256 penaltyToPool);
    event FeeDistributed(address indexed user, uint256 shareFromPool);

    /**
     * @param _token ERC-20 token address to lock
     * @param _enrollmentDuration seconds during which deposits are allowed (from deploy)
     * @param _lockDuration seconds of lock AFTER enrollment ends (payoutTime = enrollmentEnd + lockDuration)
     */
    constructor(address _token, uint256 _enrollmentDuration, uint256 _lockDuration) {
        require(_token != address(0), "token=0");
        token = IERC20(_token);

        uint256 _enrollEnd = block.timestamp + _enrollmentDuration;
        enrollmentEnd = _enrollEnd;
        payoutTime = _enrollEnd + _lockDuration;
    }

    // ---------- Views ----------

    function tokenAddress() external view returns (address) {
        return address(token);
    }

    function timeUntilPayout() external view returns (uint256) {
        if (block.timestamp >= payoutTime) return 0;
        return payoutTime - block.timestamp;
    }

    function getAccount(address user) external view returns (uint256 entitlement, uint256 deposited) {
        Account storage a = accounts[user];
        return (a.entitlement, a.deposited);
    }

    // ---------- Core logic ----------

    /**
     * @notice Deposit `amount` tokens during the enrollment window.
     *         Multiple deposits are allowed; this simply adds to your stake & entitlement.
     *         Caller must approve this contract for at least `amount`.
     */
    function deposit(uint256 amount) external nonReentrant {
        require(block.timestamp < enrollmentEnd, "Enrollment ended");
        require(amount > 0, "amount=0");

        _safeTransferFrom(msg.sender, address(this), amount);

        Account storage user = accounts[msg.sender];
        user.deposited += amount;
        user.entitlement += amount; // mirrors base behavior: stake increases entitlement 1:1
        totalDeposits += amount;

        emit Deposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw a chosen `amount` (partial or full).
     *         Phase rules:
     *          - Before enrollmentEnd: full payout on withdrawn slice (no penalty).
     *          - Between enrollmentEnd and payoutTime:
     *                * If this withdrawal empties the pool (i.e., after accounting, totalDeposits==0),
     *                  NO penalty on this withdrawn slice (avoid stranding).
     *                * Else 20% penalty on withdrawn slice -> feePool.
     *          - After payoutTime: full payout (no penalty).
     */
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");

        Account storage user = accounts[msg.sender];
        uint256 userDep = user.deposited;
        require(userDep >= amount, "insufficient deposited");
        require(totalDeposits >= amount, "pool accounting error");

        // 1) Distribute feePool proportionally to the WITHDRAWN amount
        //    share = (amount / totalDeposits) * feePool
        uint256 share = 0;
        if (feePool > 0) {
            share = (amount * feePool) / totalDeposits;
            if (share > 0) {
                user.entitlement += share;
                feePool -= share;
                emit FeeDistributed(msg.sender, share);
            }
        }

        // 2) Compute the entitlement slice to pay out for this partial
        //    entitlement scales with stake; take proportional slice:
        //    slice = user.entitlement * (amount / userDep_before)
        //    (use userDep saved above as the "before" value)
        uint256 slice = (user.entitlement * amount) / userDep;

        // 3) Update user & pool accounting for the withdrawn amount
        user.deposited = userDep - amount;
        user.entitlement -= slice;
        totalDeposits -= amount;

        // 4) Determine phase & whether this makes user the last staker
        bool emptiesPool = (totalDeposits == 0); // i.e., this withdrawal removed the last remaining stake

        uint256 pay;
        uint256 penalty;

        if (block.timestamp < enrollmentEnd) {
            // Enrollment phase: no penalty
            pay = slice;
        } else if (block.timestamp >= payoutTime) {
            // Post-lock: no penalty
            pay = slice;
        } else {
            // Mid-game window
            if (emptiesPool) {
                // Last-staker-friendly: no penalty on withdrawn slice
                pay = slice;
            } else {
                // Standard 20% penalty on the withdrawn slice
                pay = (slice * 4) / 5;
                penalty = slice - pay; // 20%
                feePool += penalty;
            }
        }

        _safeTransfer(msg.sender, pay);

        if (user.deposited == 0) {
            emit WithdrawnAll(msg.sender, pay, penalty);
        } else {
            emit PartialWithdrawn(msg.sender, amount, pay, penalty);
        }
    }

    // ---------- Internal safe transfer helpers ----------

    function _safeTransfer(address to, uint256 amount) internal {
        if (amount == 0) return;
        bool ok = token.transfer(to, amount);
        require(ok, "transfer failed");
    }

    function _safeTransferFrom(address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        bool ok = token.transferFrom(from, to, amount);
        require(ok, "transferFrom failed");
    }
}
