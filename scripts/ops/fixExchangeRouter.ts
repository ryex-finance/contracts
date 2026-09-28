/**
 * GMX Arbitrum Sepolia ExchangeRouter 교체.
 * 옛 라우터(0xEd50B2A1...)는 옛 OrderHandler에 붙어 LimitIncrease가 DisabledFeature로 거부됨.
 *
 *   npx hardhat run scripts/ops/fixExchangeRouter.ts --network arbitrumSepolia
 */
import { ethers } from "hardhat";

const FACTORY = "0x464D37E6E312d30c3c6e106255e88127C9F2d33c";
const NEW_EXCHANGE_ROUTER = "0x6B489dD5bB1AAE8df246359d59aA7316760a75d2";

async function main() {
  const [signer] = await ethers.getSigners();
  const factory = await ethers.getContractAt("VaultFactory", FACTORY, signer);
  const before = await factory.gmxInfra();
  console.log("signer:", await signer.getAddress());
  console.log("현재 exchangeRouter:", before.exchangeRouter);
  console.log("현재 orderHandler  :", before.orderHandler);

  if (before.exchangeRouter.toLowerCase() === NEW_EXCHANGE_ROUTER.toLowerCase()) {
    console.log("이미 최신 exchangeRouter입니다.");
    return;
  }

  const tx = await factory.setGmxInfra({
    exchangeRouter: NEW_EXCHANGE_ROUTER,
    gmxRouter: before.gmxRouter,
    orderVault: before.orderVault,
    reader: before.reader,
    dataStore: before.dataStore,
    orderHandler: before.orderHandler,
    execFee: before.execFee,
    acceptablePriceMax: before.acceptablePriceMax,
    acceptablePriceMin: before.acceptablePriceMin,
  });
  const rc = await tx.wait();
  console.log("setGmxInfra tx:", rc?.hash);

  const after = await factory.gmxInfra();
  console.log("확인된 exchangeRouter:", after.exchangeRouter);
  if (after.exchangeRouter.toLowerCase() !== NEW_EXCHANGE_ROUTER.toLowerCase()) {
    throw new Error("exchangeRouter 업데이트 실패");
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
