// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * Tontine over an arbitrary ERC20.
 * - Multiple deposits during enrollment.
 * - Partial withdrawals anytime; penalty logic:
 *      * Before enrollment end: 0% penalty
 *      * After payout time: 0% penalty
 *      * Between: 20% penalty UNLESS last staker (penalty waived)
 * - Fee (penalty) distributions exclude the payer from earning on their own fees.
 * - No stranded fees: penalties go to others via accFeePerShare, harvested on actions.
 */
contract TontineERC20_ExcludeSelf {
    using SafeERC20 for IERC20;

    // ----- Config -----
    IERC20 public immutable token;
    uint256 public immutable enrollmentEnd; // timestamp
    uint256 public immutable payoutTime;    // timestamp

    // ----- Accounting -----
    uint256 public totalDeposits;       // active principal across all users
    uint256 public feePool;             // undistributed fees not yet moved into user entitlements

    // Accumulator for fee distributions
    uint256 private constant ACC_PRECISION = 1e18;
    uint256 private accFeePerShare;     // scaled by ACC_PRECISION

    struct Account {
        uint256 entitlement;  // claimable fees harvested for the user, paid out on withdrawals
        uint256 deposited;    // principal currently staked
        uint256 rewardDebt;   // deposited * accFeePerShare at last update (scaled)
    }

    mapping(address => Account) public accounts;

    // ----- Events -----
    event Deposited(address indexed user, uint256 amount);
    event FeeDistributed(address indexed user, uint256 shareFromPool);
    event PartialWithdrawn(address indexed user, uint256 amountRequested, uint256 paidOut, uint256 penaltyToPool);
    event WithdrawnAll(address indexed user, uint256 paidOut, uint256 penaltyToPool);

    constructor(address _token, uint256 _enrollmentDuration, uint256 _lockDuration) {
        require(_token != address(0), "token=0");
        token = IERC20(_token);
        // enrollment starts now and ends after _enrollmentDuration seconds
        enrollmentEnd = block.timestamp + _enrollmentDuration;
        // payout (lock) ends after enrollment + _lockDuration seconds
        payoutTime = enrollmentEnd + _lockDuration;
    }

    // ----- Views -----

    function getAccount(address user) external view returns (uint256 entitlement, uint256 deposited) {
        Account storage a = accounts[user];
        entitlement = a.entitlement + _pending(a);
        deposited = a.deposited;
    }

    function timeUntilPayout() external view returns (uint256) {
        if (block.timestamp >= payoutTime) return 0;
        return payoutTime - block.timestamp;
    }

    // ----- Core actions -----

    function deposit(uint256 amount) external {
        require(block.timestamp < enrollmentEnd, "Enrollment ended");
        require(amount > 0, "amount=0");

        Account storage a = accounts[msg.sender];

        // Harvest existing pending fees first
        _harvest(a);

        // Pull tokens
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Update principal & global
        a.deposited += amount;
        totalDeposits += amount;

        // Reset rewardDebt to current index
        a.rewardDebt = (a.deposited * accFeePerShare) / ACC_PRECISION;

        emit Deposited(msg.sender, amount);
    }

    /**
     * Withdraw an amount of principal (partial or full).
     * Pays out: (withdrawAmount - penalty) + full current entitlement.
     */
    function withdraw(uint256 amount) external {
        Account storage a = accounts[msg.sender];
        require(amount > 0, "amount=0");
        require(a.deposited >= amount, "insufficient deposited");

        // Harvest fees accrued so far (excludes user's own past penalties by construction)
        _harvest(a);

        // Determine penalty rate
        uint256 penaltyRate = _penaltyRate(amount, a.deposited);
        uint256 penalty = (amount * penaltyRate) / 100;
        uint256 payout = amount - penalty;

        // Update principal & totals before distributing penalty,
        // so last-man-standing check works correctly in future calls.
        a.deposited -= amount;
        totalDeposits -= amount;

        // Distribute penalty to others (excludes msg.sender automatically)
        if (penalty > 0) {
            _distributeFeeExcluding(penalty, a);
        }

        // Pay out user's entitlement + principal less penalty
        uint256 toPay = payout + a.entitlement;
        if (toPay > 0) {
            token.safeTransfer(msg.sender, toPay);
            emit FeeDistributed(msg.sender, a.entitlement);
            a.entitlement = 0;
        }

        // Update rewardDebt to new base
        a.rewardDebt = (a.deposited * accFeePerShare) / ACC_PRECISION;

        if (a.deposited == 0) {
            emit WithdrawnAll(msg.sender, toPay, penalty);
        } else {
            emit PartialWithdrawn(msg.sender, amount, toPay, penalty);
        }
    }

    // ----- Internals -----

    function _penaltyRate(uint256 /*amount*/, uint256 userDeposited) internal view returns (uint256) {
        // Last man standing (only staker): no penalty anytime
        if (totalDeposits == userDeposited) return 0;

        // Before enrollment end: no penalty
        if (block.timestamp <= enrollmentEnd) return 0;

        // After payout time: no penalty
        if (block.timestamp >= payoutTime) return 0;

        // Otherwise during lock window: 20%
        return 20;
    }

    function _pending(Account storage a) internal view returns (uint256) {
        uint256 accumulated = (a.deposited * accFeePerShare) / ACC_PRECISION;
        if (accumulated <= a.rewardDebt) return 0;
        return accumulated - a.rewardDebt;
    }

    function _harvest(Account storage a) internal {
        uint256 pending = _pending(a);
        if (pending > 0) {
            // Move from global pool to user's entitlement
            // (feePool tracks undistributed—reduce as we harvest)
            feePool -= pending;
            a.entitlement += pending;
        }
        // Sync reward debt to current index
        a.rewardDebt = (a.deposited * accFeePerShare) / ACC_PRECISION;
    }

    /**
     * Distribute a penalty amount to all stakers EXCEPT `excluder`.
     * Implements: acc += amount / (totalDeposits - excluderDeposit)
     * and offsets excluder's rewardDebt so they don't accrue from their own penalty.
     */
    function _distributeFeeExcluding(uint256 amount, Account storage exAcc) internal {
        if (amount == 0) return;

        uint256 base = totalDeposits; // NOTE: at this point we've already reduced totalDeposits for caller's withdrawal
        uint256 exclDeposit = exAcc.deposited;
        // baseExcl is the pool of recipients (everyone except excluder)
        uint256 baseExcl = base - exclDeposit;

        // If no one else to receive (should only happen if excluder is sole staker),
        // do nothing here: but _penaltyRate() ensures penalty=0 in that case.
        if (baseExcl == 0) return;

        // Increase acc for everyone
        uint256 delta = (amount * ACC_PRECISION) / baseExcl;
        accFeePerShare += delta;

        // Offset excluder’s potential accrual from this delta
        // so that pending = deposited*acc - rewardDebt doesn't include their own penalty
        exAcc.rewardDebt += (exAcc.deposited * delta) / ACC_PRECISION;

        // Track pool growth for visibility; it will shrink as users harvest
        feePool += amount;
    }
}