/**
 * GMX OrderHandler 콜백만으로 vault 상태 전환을 기다림.
 * settleGmxOrder는 호출하지 않음 (복구용 onlyOwner 경로).
 */
import type { Contract } from "ethers";

export const DEFAULT_SETTLE_TIMEOUT_MS = 180_000;
export const POLL_MS = 5_000;

export type VaultStatePred = (state: bigint) => boolean | Promise<boolean>;

export async function waitVault(
  vault: Contract,
  pred: VaultStatePred,
  opts: { timeoutMs?: number; label?: string; pollMs?: number } = {},
): Promise<bigint> {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_SETTLE_TIMEOUT_MS;
  const pollMs = opts.pollMs ?? POLL_MS;
  const label = opts.label ?? "waitVault";
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const state: bigint = await vault.state();
    if (await pred(state)) return state;
    await new Promise((r) => setTimeout(r, pollMs));
  }
  const finalState: bigint = await vault.state();
  throw new Error(`${label}: timed out (state=${finalState})`);
}

/** SettlingOpen(1) → Active(2). 취소되면 Empty(0)면 에러. */
export async function waitOpenActive(
  vault: Contract,
  opts: { timeoutMs?: number; label?: string } = {},
): Promise<void> {
  await waitVault(
    vault,
    async (s) => {
      if (s === 2n) return true;
      if (s === 0n) throw new Error(`${opts.label ?? "waitOpenActive"}: open cancelled (Empty)`);
      return false;
    },
    { ...opts, label: opts.label ?? "waitOpenActive" },
  );
}

/** SettlingLiquidate(3) 또는 close 후 Empty(0). */
export async function waitClosedEmpty(
  vault: Contract,
  opts: { timeoutMs?: number; label?: string } = {},
): Promise<void> {
  await waitVault(vault, (s) => s === 0n, { ...opts, label: opts.label ?? "waitClosedEmpty" });
}

/** 지정 state에 도달할 때까지 (취소/실패 허용 시 allowStates 사용). */
export async function waitStateIn(
  vault: Contract,
  states: bigint[],
  opts: { timeoutMs?: number; label?: string } = {},
): Promise<bigint> {
  const set = new Set(states.map(String));
  return waitVault(vault, (s) => set.has(s.toString()), {
    ...opts,
    label: opts.label ?? `waitStateIn([${states.join(",")}])`,
  });
}
