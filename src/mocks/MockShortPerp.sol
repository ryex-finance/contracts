// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title MockShortPerp — funding-bearing SHORT perp for the rYield strategy (demo).
/// @notice The delta-neutral hedge's funding leg: an account opens a USDC-margined
///         short of `sizeUsdc` notional and *receives* funding while the rate is
///         positive (the long side pays). Funding accrues against a cumulative
///         index advanced by `pokeFunding` (one poke = one funding period, like a
///         perp's 8h rate), and is paid in USDC from the contract's seeded funding
///         pool — the demo stand-in for real counterparty funding. Price PnL is
///         short-signed (profit when price falls); in a delta-neutral position it is
///         offset by the rToken long leg.
/// @dev Single counterparty pool model (no orderbook). margin + funding pool live in
///      this contract's USDC balance; seed it at deploy. Owner sets the funding rate.
contract MockShortPerp is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc; // 6dec
    IPriceOracle public immutable oracle; // 8dec price
    bytes32 public immutable marketId;

    uint8 public constant MAX_LEVERAGE = 10;
    uint256 internal constant BPS = 10_000;

    /// Cumulative funding index in bps of notional (advanced by pokeFunding).
    uint256 public fundingIndex;
    uint256 public nonce;

    struct Position {
        address owner;
        uint256 margin; // USDC 6dec
        uint256 sizeUsdc; // short notional, USDC 6dec
        uint256 entryPrice8; // oracle price at open (8dec)
        uint256 entryFundingIndex;
        bool open;
    }

    mapping(bytes32 => Position) public positions;

    event ShortOpened(bytes32 indexed key, address indexed owner, uint256 margin, uint256 sizeUsdc, uint256 entryPrice8);
    event FundingPoked(uint256 rateBps, uint256 newIndex);
    event FundingClaimed(bytes32 indexed key, uint256 amount);
    event ShortClosed(bytes32 indexed key, uint256 payout);

    error BadLeverage();
    error ZeroAmount();
    error NotPositionOwner();
    error NotOpen();

    constructor(IERC20 usdc_, IPriceOracle oracle_, bytes32 marketId_, address owner_) Ownable(owner_) {
        require(address(usdc_) != address(0) && address(oracle_) != address(0), "zero addr");
        usdc = usdc_;
        oracle = oracle_;
        marketId = marketId_;
    }

    modifier onlyPosOwner(bytes32 key) {
        if (positions[key].owner != msg.sender) revert NotPositionOwner();
        if (!positions[key].open) revert NotOpen();
        _;
    }

    /// @notice Open a short: pull `marginUsdc`, record a `sizeUsdc` short at the oracle price.
    function openShort(uint256 marginUsdc, uint256 sizeUsdc) external returns (bytes32 key) {
        if (marginUsdc == 0 || sizeUsdc == 0) revert ZeroAmount();
        if (sizeUsdc > marginUsdc * MAX_LEVERAGE) revert BadLeverage();
        usdc.safeTransferFrom(msg.sender, address(this), marginUsdc);
        key = keccak256(abi.encodePacked(msg.sender, marketId, nonce++));
        positions[key] =
            Position(msg.sender, marginUsdc, sizeUsdc, oracle.getPrice(), fundingIndex, true);
        emit ShortOpened(key, msg.sender, marginUsdc, sizeUsdc, oracle.getPrice());
    }

    /// @notice Advance funding by `rateBps` of notional for this period (governance/keeper).
    function pokeFunding(uint256 rateBps) external onlyOwner {
        fundingIndex += rateBps;
        emit FundingPoked(rateBps, fundingIndex);
    }

    /// @notice Funding accrued to a position since its last claim (USDC, from the pool).
    function accruedFunding(bytes32 key) public view returns (uint256) {
        Position storage p = positions[key];
        if (!p.open) return 0;
        return (p.sizeUsdc * (fundingIndex - p.entryFundingIndex)) / BPS;
    }

    /// @notice Realize accrued funding to USDC without closing (the keeper harvests this).
    function claimFunding(bytes32 key) external onlyPosOwner(key) returns (uint256 amount) {
        amount = accruedFunding(key);
        positions[key].entryFundingIndex = fundingIndex;
        if (amount > 0) usdc.safeTransfer(msg.sender, amount);
        emit FundingClaimed(key, amount);
    }

    /// @notice Signed price PnL of the short (profit when price falls), USDC 6dec.
    function pricePnl(bytes32 key) public view returns (int256) {
        Position storage p = positions[key];
        if (!p.open) return 0;
        int256 entry = int256(p.entryPrice8);
        int256 cur = int256(oracle.getPrice());
        return (int256(p.sizeUsdc) * (entry - cur)) / entry;
    }

    /// @notice Mark-to-market value of the position in USDC (margin + price PnL + funding), floored at 0.
    function positionValueUsdc(bytes32 key) external view returns (uint256) {
        Position storage p = positions[key];
        if (!p.open) return 0;
        int256 v = int256(p.margin) + pricePnl(key) + int256(accruedFunding(key));
        return v > 0 ? uint256(v) : 0;
    }

    /// @notice Close the short → returns margin + price PnL + accrued funding (floored at 0).
    function closeShort(bytes32 key) external onlyPosOwner(key) returns (uint256 payout) {
        int256 v = int256(positions[key].margin) + pricePnl(key) + int256(accruedFunding(key));
        payout = v > 0 ? uint256(v) : 0;
        positions[key].open = false;
        if (payout > 0) usdc.safeTransfer(msg.sender, payout);
        emit ShortClosed(key, payout);
    }
}
