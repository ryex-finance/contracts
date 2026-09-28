/**
 * GMX v2 Arbitrum Sepolia 배포 주소 (chainId 421614)
 * 출처: gmx-synthetics/deployments/arbitrumSepolia
 *
 * 마켓 토큰 조회:
 *   Reader.getMarkets(DATA_STORE, 0, 30) @ READER
 */
export const GMX = {
  DATA_STORE:   "0xCF4c2C4c53157BcC01A596e3788fFF69cBBCD201",
  ROLE_STORE:   "0x433E3C47885b929aEcE4149E3c835E565a20D95c",
  READER:       "0x4750376b9378294138Cf7B7D69a2d243f4940f71",

  /// @dev 옛 ExchangeRouter(0xEd50B2A1...)는 옛 OrderHandler로 붙어 있어 LimitIncrease 생성이
  ///      DisabledFeature로 거부됨 (2026-08-20 확인). 지정가 open/increase는 이 최신 주소를 써야 함.
  EXCHANGE_ROUTER: "0x6B489dD5bB1AAE8df246359d59aA7316760a75d2",
  ROUTER:          "0x72F13a44C8ba16a678CAD549F17bc9e06d2B8bD2",
  ORDER_VAULT:     "0x1b8AC606de71686fd2a1AEDEcb6E0EFba28909a2",
  DEPOSIT_VAULT:   "0xb69Ea82C394bE8993C2B680d73B6fd07ab920e5A",
  WITHDRAWAL_VAULT:"0x7601C9dBbDc1F1f5e01E7ADBA4Efd9f12CaDa037",

  ORACLE:        "0x0dc4E24c63c24Fe898dA574C962Ba7FbB146964d",
  EVENT_EMITTER: "0xa973c2692C1556E1a3d478e745e9a75624AEDc73",

  /// @dev GMX가 테스트넷 OrderHandler를 재배포하면서 옛 주소(0x000F6926...)로는
  ///      afterOrderExecution 콜백이 _requireGmxHandler()에서 거부돼 vault가
  ///      SettlingOpen에 멈추는 문제가 있었음 (2026-08-20 확인, on-chain 재현·수정 완료).
  ///      새로 addMarket/deployGmxA1 재배포 시 이 최신 주소를 사용해야 함.
  /// @dev 2026-09-25 확인: GMX 테스트넷 키퍼가 실제 execute를 이 주소로 보냄(docs/master는 아직 옛 0xC881c239...).
  ///      afterOrderExecution 콜백 신뢰 주체 — factory.setGmxInfra로 이미 전환 완료, config도 동기화.
  ORDER_HANDLER:       "0xc63632D7AD3f506081d270A4C3E084f9e76Cee64",
  DEPOSIT_HANDLER:     "0xD06228e2886A348209F777c82c90515f9DA1b790",
  WITHDRAWAL_HANDLER:  "0x039dDEe97368EB6ed20cE921De7a037a92A1a566",
  ADL_HANDLER:         "0x6d8437132784CDDF0cCa3Da249EF49F92947EEE4",
  LIQUIDATION_HANDLER: "0x268fA5c1dAfEEFD5E78c31cF517C780cB36e7A84",

  MARKET_FACTORY: "0x1934838E3d85416A6cF5bF7A5E619f12BE01C4b2",

  MARKET_ETH: "0xb6fC4C9eB02C35A134044526C62bb15014Ac0Bcc",
  MARKET_BTC: "0x3A83246bDDD60c4e71c91c10D9A66Fd64399bBCf",

  TOKEN_WETH: "0x980B62Da83eFf3D4576C647993b0c1D7faf17c73",
  TOKEN_BTC:  "0xF79cE1Cf38A09D572b021B4C5548b75A14082F12",

  USDC: "0x3253a335E7bFfB4790Aa4C25C4250d206E9b9773",

  /** GMX ChainlinkPriceFeedProvider — index token USD (30 dec) */
  CHAINLINK_PRICE_FEED_PROVIDER: "0xa76BF7f977E80ac0bff49BDC98a27b7b070a937d",
} as const;

/** Ryex 배포 UniV3 (scripts/deploy/v3/deployUniswapV3.ts) */
export const UNIV3 = {
  SWAP_ROUTER: "0x8d7bb3198C0C84eB90cc765c334D178f8a399d70",
  NPM:         "0x5F1cAD937D928a6C8b6dC89478F38d9E13764aD9",
  FACTORY:     "0x58dbEd38eC5a992b851a1624134bB895Ec27050A",
} as const;
