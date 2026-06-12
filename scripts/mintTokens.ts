import { expect } from "chai";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { ethers, network } from "hardhat";
import { ERC20PresetMinterPauser__factory } from "../typechain-types";


type DeploymentsFile = {
  tokens: Record<string, string>;
};

const ERC20_MINTER_ABI = [
  "function mint(address to, uint256 amount) external",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
];


async function main() {
  describe("Token Mint (Hardhat)", function () {
    it("mints requested amount to one selected token", async function () {
      const [signer] = await ethers.getSigners();
      const minter = await signer.getAddress();

      const deploymentsPath = path.join(process.cwd(), "deployments", `tokens.${network.name}.json`);
      const raw = await readFile(deploymentsPath, "utf8");
      const parsed = JSON.parse(raw) as DeploymentsFile;
      const RECIPIENT = "0x8A3Be22fB5cFD54a436C5ebEa63f40062B0E8856";
      const TARGET_SYMBOL = "USDC";
      const tokenAddress = parsed.tokens?.[TARGET_SYMBOL];
      if (!tokenAddress) {
        throw new Error(`token '${TARGET_SYMBOL}' not found in ${deploymentsPath}`);
      }

      const token = ERC20PresetMinterPauser__factory.connect(tokenAddress, signer);
      const decimals = await token.decimals();
      const mintAmount = ethers.parseUnits("1000000", decimals);
      const before = await token.balanceOf(RECIPIENT);

      const tx = await token.mint(RECIPIENT, mintAmount);
      const receipt = await tx.wait();
      const after = await token.balanceOf(RECIPIENT);
      const diff = after - before;

      expect(diff).to.equal(mintAmount);

      console.log(`network=${network.name}`);
      console.log(`minter=${minter}`);
      console.log(`symbol=${TARGET_SYMBOL}`);
      console.log(`recipient=${RECIPIENT}`);
      console.log(
        `${TARGET_SYMBOL} minted=${ethers.formatUnits(mintAmount, decimals)} tx=${receipt?.hash ?? ""} before=${ethers.formatUnits(before, decimals)} after=${ethers.formatUnits(after, decimals)}`,
      );
    });

    it("mints requested amount to recipient for all deployed tokens", async function () {
      const [signer] = await ethers.getSigners();
      const minter = await signer.getAddress();
      const recipient = "0x8A3Be22fB5cFD54a436C5ebEa63f40062B0E8856";
      const humanAmount = "100000";

      const deploymentsPath = path.join(process.cwd(), "deployments", `tokens.${network.name}.json`);
      const raw = await readFile(deploymentsPath, "utf8");
      const parsed = JSON.parse(raw) as DeploymentsFile;
      const entries = Object.entries(parsed.tokens ?? {});
      if (entries.length === 0) {
        throw new Error(`no tokens found in ${deploymentsPath}`);
      }

      console.log(`network=${network.name}`);
      console.log(`minter=${minter}`);
      console.log(`recipient=${recipient}`);
      console.log(`humanAmount=${humanAmount}`);

      for (const [symbol, tokenAddress] of entries) {
        const token = ERC20PresetMinterPauser__factory.connect(tokenAddress, signer);
        const decimals = await token.decimals();
        const mintAmount = ethers.parseUnits(humanAmount, decimals);
        const before = await token.balanceOf(recipient);

        const tx = await token.mint(recipient, mintAmount);
        const receipt = await tx.wait();
        const after = await token.balanceOf(recipient);
        const diff = after - before;

        expect(diff).to.equal(mintAmount);

        console.log(
          `${symbol} minted=${ethers.formatUnits(mintAmount, decimals)} tx=${receipt?.hash ?? ""} before=${ethers.formatUnits(before, decimals)} after=${ethers.formatUnits(after, decimals)}`,
        );
      }
    });

    it("mints 10000 of each token to two recipients", async function () {
      const [signer] = await ethers.getSigners();
      const minter = await signer.getAddress();
      const recipients = [
        "0xDC7fCD25178a32ED003558d57e59E1C62B47C717",
        "0x6fa85f04d1658f8d4101bc0bbbd59753353ea2b9",
      ];
      const humanAmount = "10000";

      const deploymentsPath = path.join(process.cwd(), "deployments", `tokens.${network.name}.json`);
      const raw = await readFile(deploymentsPath, "utf8");
      const parsed = JSON.parse(raw) as DeploymentsFile;
      const entries = Object.entries(parsed.tokens ?? {});
      if (entries.length === 0) {
        throw new Error(`no tokens found in ${deploymentsPath}`);
      }

      console.log(`network=${network.name}`);
      console.log(`minter=${minter}`);
      console.log(`humanAmount=${humanAmount}`);

      for (const [symbol, tokenAddress] of entries) {
        const token = new ethers.Contract(tokenAddress, ERC20_MINTER_ABI, signer);
        const decimals: number = await token.decimals();
        const mintAmount = ethers.parseUnits(humanAmount, decimals);

        for (const recipient of recipients) {
          const before: bigint = await token.balanceOf(recipient);
          const tx = await token.mint(recipient, mintAmount);
          const receipt = await tx.wait();
          const after: bigint = await token.balanceOf(recipient);
          const diff = after - before;

          expect(diff).to.equal(mintAmount);

          console.log(
            `${symbol} → ${recipient} minted=${ethers.formatUnits(mintAmount, decimals)} tx=${receipt?.hash ?? ""} before=${ethers.formatUnits(before, decimals)} after=${ethers.formatUnits(after, decimals)}`,
          );
        }
      }
    });
  });
}

void main();
