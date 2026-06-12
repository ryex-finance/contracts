/**
 * GMX v2 Arbitrum Sepolia 배포 주소 (chainId 421614)
 * 출처: gmx-synthetics/deployments/arbitrumSepolia
 * Solidity 버전: script/config/GmxArbitrumSepolia.sol
 */
export const GMX = {
  // ── 핵심 저장소 ──────────────────────────────────────────────────────────
  DATA_STORE:   "0xCF4c2C4c53157BcC01A596e3788fFF69cBBCD201",
  ROLE_STORE:   "0x433E3C47885b929aEcE4149E3c835E565a20D95c",

  // ── 조회 ─────────────────────────────────────────────────────────────────
  READER:       "0x4750376b9378294138Cf7B7D69a2d243f4940f71",

  // ── 주문 실행 ─────────────────────────────────────────────────────────────
  EXCHANGE_ROUTER: "0xEd50B2A1eF0C35DAaF08Da6486971180237909c3",
  ROUTER:          "0x72F13a44C8ba16a678CAD549F17bc9e06d2B8bD2",
  ORDER_VAULT:     "0x1b8AC606de71686fd2a1AEDEcb6E0EFba28909a2",
  DEPOSIT_VAULT:   "0xb69Ea82C394bE8993C2B680d73B6fd07ab920e5A",
  WITHDRAWAL_VAULT:"0x7601C9dBbDc1F1f5e01E7ADBA4Efd9f12CaDa037",

  // ── 오라클 & 이벤트 ───────────────────────────────────────────────────────
  ORACLE:        "0x0dc4E24c63c24Fe898dA574C962Ba7FbB146964d",
  EVENT_EMITTER: "0xa973c2692C1556E1a3d478e745e9a75624AEDc73",

  // ── 핸들러 ────────────────────────────────────────────────────────────────
  ORDER_HANDLER:       "0x000F692690F6C39660AfB878D277f038fb3a8eC6",
  DEPOSIT_HANDLER:     "0xD06228e2886A348209F777c82c90515f9DA1b790",
  WITHDRAWAL_HANDLER:  "0x039dDEe97368EB6ed20cE921De7a037a92A1a566",
  ADL_HANDLER:         "0x6d8437132784CDDF0cCa3Da249EF49F92947EEE4",
  LIQUIDATION_HANDLER: "0x268fA5c1dAfEEFD5E78c31cF517C780cB36e7A84",

  // ── 팩토리 ────────────────────────────────────────────────────────────────
  MARKET_FACTORY: "0x1934838E3d85416A6cF5bF7A5E619f12BE01C4b2",

  // ── GMX 마켓 토큰 (Reader.getMarkets로 조회 확인) ────────────────────────
  MARKET_ETH: "0xb6fC4C9eB02C35A134044526C62bb15014Ac0Bcc", // WETH/USDC
  MARKET_BTC: "0x3A83246bDDD60c4e71c91c10D9A66Fd64399bBCf", // BTC/USDC (BTC 8dec)

  // ── 인덱스 토큰 (GMX 테스트넷 합성 자산) ─────────────────────────────────
  TOKEN_WETH: "0x980B62Da83eFf3D4576C647993b0c1D7faf17c73", // 18dec
  TOKEN_BTC:  "0xF79cE1Cf38A09D572b021B4C5548b75A14082F12", // 8dec (synthetic)

  // ── 담보 토큰 (GMX 테스트넷 USDC, 6dec) ──────────────────────────────────
  USDC: "0x3253a335E7bFfB4790Aa4C25C4250d206E9b9773",
} as const;
