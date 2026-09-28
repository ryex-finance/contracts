// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IRToken} from "../interfaces/IRToken.sol";
import {Units} from "./Units.sol";

/// @title DebtSettler — 청산·종료·redeem 부채/USDC 정산 (external library, delegatecall from vault).
library DebtSettler {
    using SafeERC20 for IERC20;

    /// @notice 청산 부채정산 결과 로그.
    /// @dev earmarkedRToken은 "이 tx에서 즉시 태운 양"이 아니라 오라클가로 확정해서
    ///      factory 대기버킷에 적립한 예정 소각량. 실제 burn은 나중에 VaultFactory.buybackAndBurn()이 수행.
    ///      ownerBurned만 이 tx 안에서 즉시(무료) 소각된다 — owner가 아직 보유 중인 shortfall 커버분.
    event LiquidationDebtSettled(
        address indexed vault, uint256 earmarkedRToken, uint256 earmarkedUsdc, uint256 ownerBurned, uint256 badDebtRToken
    );

    struct LiqRepayResult {
        uint256 newDebt; // 진짜 못 갚은 부채(GMX 포지션 자체 shortfall — buyback 메커니즘과 무관한 bad debt)
        uint256 usdcSpent; // 대기버킷으로 나간 USDC(6dec)
        uint256 earmarkedRToken; // 대기버킷에 적립된 예정 소각량(18dec, 아직 미소각)
        uint256 ownerBurned; // owner 보유분에서 즉시 무료 소각(18dec)
    }

    struct ExitResult {
        uint256 refund;
        uint256 usdcDebtSpent;
        uint256 keeperBounty;
        uint256 fees;
        uint256 toTreasury;
        uint256 badDebtShortfall;
        uint256 newDebt;
    }

    struct CloseResult {
        uint256 fees;
        uint256 toOwner;
    }

    /// @notice 오라클가 확정정산 + 대기버킷 적립. 이 tx 안에서 AMM 스왑을 하지 않는다(설계 변경 핵심,
    ///         docs/liquidation-branches.md). `repayBudget`(recovered USDC, USD상 debt 상한)만큼을
    ///         오라클가로 대기버킷에 적립하면 vault 자신의 부채는 즉시 0으로 정산 완료된다.
    ///         실제 시중 rToken 회수+소각은 나중에 VaultFactory.buybackAndBurn()이 담당(트레저리 자본 불필요).
    /// @dev `newDebt`(반환)은 오직 "recovered 담보가치 < 부채 오라클가치"인 진짜 shortfall만 남는다 —
    ///      이건 buyback 메커니즘과 무관한, GMX 포지션 자체의 실물 손실이다.
    function liquidationRepayDebt(
        address owner,
        address factory,
        bytes32 marketId,
        IPriceOracle oracle,
        IERC20 usdc,
        IRToken rToken,
        uint256 debt,
        uint256 repayBudget
    ) internal returns (LiqRepayResult memory r) {
        if (debt == 0) return r;

        uint256 price8 = oracle.getPrice();
        uint256 debtUsdc = Units.wadToUsdc(Units.rTokenToUsdWad(debt, price8));
        uint256 earmarkUsdc = repayBudget < debtUsdc ? repayBudget : debtUsdc;

        uint256 remaining = debt;
        if (earmarkUsdc > 0) {
            // 정상 케이스(예산이 충분)엔 반올림 없이 debt 전액을 그대로 적립 — dust 방지.
            uint256 earmarkRToken = earmarkUsdc == debtUsdc
                ? debt
                : Units.usdWadToRToken(Units.usdcToWad(earmarkUsdc), price8);
            if (earmarkRToken > remaining) earmarkRToken = remaining;

            usdc.safeTransfer(factory, earmarkUsdc);
            IVaultFactory(factory).notifyLiquidationEarmark(marketId, earmarkUsdc, earmarkRToken);

            remaining -= earmarkRToken;
            r.earmarkedRToken = earmarkRToken;
            r.usdcSpent = earmarkUsdc;
        }

        // 진짜 shortfall(=recovered 담보가치 < 부채가치)만 남은 경우 — owner가 아직 보유 중이면 무료 소각(최후수단).
        if (remaining > 0) {
            uint256 ownerBal = IERC20(address(rToken)).balanceOf(owner);
            uint256 fromOwner = ownerBal > remaining ? remaining : ownerBal;
            if (fromOwner > 0) {
                rToken.burn(owner, fromOwner);
                remaining -= fromOwner;
                r.ownerBurned = fromOwner;
            }
        }

        r.newDebt = remaining;
        emit LiquidationDebtSettled(address(this), r.earmarkedRToken, r.usdcSpent, r.ownerBurned, r.newDebt);
    }

    /// @dev fee(mint/redeem + borrow) 총액을 treasury·LP인센티브 몫으로 분리.
    ///      mint/redeem fee(accruedFeesUsdc)가 항상 우선 지급되고, borrow fee는 그 다음
    ///      순서로 지급된 만큼만 factory.borrowFeeToLpBps 비율로 LP/treasury에 나뉜다
    ///      (파산 등으로 `feePaid` < 누적 총액일 때만 이 우선순위가 실제로 갈린다).
    function _splitFee(address factory, uint256 accruedFeesUsdc, uint256 feePaid)
        private
        view
        returns (uint256 toTreasury, uint256 toLp)
    {
        uint256 mintRedeemPaid = accruedFeesUsdc > feePaid ? feePaid : accruedFeesUsdc;
        uint256 borrowFeePaid = feePaid - mintRedeemPaid;
        toLp = (borrowFeePaid * IVaultFactory(factory).borrowFeeToLpBps()) / 10_000;
        toTreasury = mintRedeemPaid + (borrowFeePaid - toLp);
    }

    /// @dev borrow fee 중 LP 몫을 factory 대기버킷으로 전송+통보(청산 earmark와 동일 패턴).
    function _payLp(address factory, bytes32 marketId, IERC20 usdc, uint256 amount) private {
        if (amount == 0) return;
        usdc.safeTransfer(factory, amount);
        IVaultFactory(factory).notifyBorrowFeeEarned(marketId, amount);
    }

    /// @dev 부채가 있는 전량 종료 정산. USDC 전송까지 수행(keeper·treasury·LP버킷·owner).
    function settleExitWithDebt(
        address owner,
        address keeper,
        address factory,
        bytes32 marketId,
        IPriceOracle oracle,
        IERC20 usdc,
        IRToken rToken,
        uint256 debt,
        uint256 accruedFeesUsdc,
        uint256 accruedBorrowFeeUsdc,
        bool applyPenalty,
        uint256 liqPenaltyBps,
        uint256 penaltyLiqShareBps
    ) external returns (ExitResult memory out) {
        uint256 recovered = usdc.balanceOf(address(this));
        uint256 debtUsdc = Units.wadToUsdc(Units.rTokenToUsdWad(debt, oracle.getPrice()));
        uint256 budget = recovered >= debtUsdc ? debtUsdc : recovered;

        LiqRepayResult memory liq = liquidationRepayDebt(owner, factory, marketId, oracle, usdc, rToken, debt, budget);
        out.usdcDebtSpent = liq.usdcSpent;

        uint256 afterDebt = recovered - out.usdcDebtSpent;
        uint256 totalFeeAccrued = accruedFeesUsdc + accruedBorrowFeeUsdc;
        out.fees = totalFeeAccrued > afterDebt ? afterDebt : totalFeeAccrued;
        uint256 afterFees = afterDebt - out.fees;
        uint256 penalty;
        if (applyPenalty) {
            penalty = (afterFees * liqPenaltyBps) / 10_000;
            if (keeper != address(0)) {
                out.keeperBounty = (penalty * penaltyLiqShareBps) / 10_000;
            }
        }
        out.refund = afterFees - penalty;

        (uint256 treasuryFeeShare, uint256 lpFeeShare) =
            _splitFee(factory, accruedFeesUsdc, out.fees);
        out.toTreasury = treasuryFeeShare + penalty - out.keeperBounty;

        address treasury = IVaultFactory(factory).treasury();
        if (out.keeperBounty > 0) usdc.safeTransfer(keeper, out.keeperBounty);
        if (out.toTreasury > 0 && treasury != address(0)) usdc.safeTransfer(treasury, out.toTreasury);
        _payLp(factory, marketId, usdc, lpFeeShare);
        if (out.refund > 0) usdc.safeTransfer(owner, out.refund);

        // liq.newDebt > 0 ⟺ recovered 담보가치 < 부채 오라클가치(진짜 GMX shortfall). buyback 대기분은
        // bad debt가 아니다 — 오라클가 100% USDC로 뒷받침되어 있고 나중에 buybackAndBurn이 소각한다.
        if (liq.newDebt > 0) {
            out.badDebtShortfall = Units.wadToUsdc(Units.rTokenToUsdWad(liq.newDebt, oracle.getPrice()));
        }
        out.newDebt = liq.newDebt;
    }

    /// @notice debt==0 전량 close — fee(mint/redeem+borrow) 분배 후 owner 환급.
    ///         borrow fee 중 factory.borrowFeeToLpBps 몫은 마켓 LP 인센티브 버킷으로, 나머지는 treasury로.
    function settleCloseNoDebt(
        address owner,
        address factory,
        bytes32 marketId,
        IERC20 usdc,
        uint256 accruedFeesUsdc,
        uint256 accruedBorrowFeeUsdc
    ) external returns (CloseResult memory out) {
        uint256 recovered = usdc.balanceOf(address(this));
        uint256 totalFeeAccrued = accruedFeesUsdc + accruedBorrowFeeUsdc;
        out.fees = totalFeeAccrued > recovered ? recovered : totalFeeAccrued;
        out.toOwner = recovered - out.fees;

        (uint256 treasuryFeeShare, uint256 lpFeeShare) =
            _splitFee(factory, accruedFeesUsdc, out.fees);

        address treasury = IVaultFactory(factory).treasury();
        if (treasuryFeeShare > 0 && treasury != address(0)) usdc.safeTransfer(treasury, treasuryFeeShare);
        _payLp(factory, marketId, usdc, lpFeeShare);
        if (out.toOwner > 0) usdc.safeTransfer(owner, out.toOwner);
    }

    /// @notice RLT redeem 정산 — fee 차감 후 redeemer에게 USDC.
    function settleRedeemPayout(
        address factory,
        IERC20 usdc,
        address redeemer,
        uint256 recovered,
        uint256 redeemFeeBps
    ) external returns (uint256 fee, uint256 toRedeemer) {
        fee = (recovered * redeemFeeBps) / 10_000;
        if (fee > recovered) fee = recovered;
        address treasury = IVaultFactory(factory).treasury();
        if (fee > 0 && treasury != address(0)) usdc.safeTransfer(treasury, fee);
        toRedeemer = recovered - fee;
        if (toRedeemer > 0) usdc.safeTransfer(redeemer, toRedeemer);
    }
}
