import { Contract, ContractFactory, ContractRunner, Signer, getAddress, type InterfaceAbi } from "ethers";

export type LinkReferences = Record<string, Record<string, { length: number; start: number }[]>>;

export type ArtifactJson = {
  abi: InterfaceAbi;
  bytecode: string;
  linkReferences?: LinkReferences;
};

export function linkLibraries(
  bytecode: string,
  linkReferences: LinkReferences,
  libraries: Record<string, string>,
): string {
  let linked = bytecode;
  for (const fileName of Object.keys(linkReferences)) {
    for (const contractName of Object.keys(linkReferences[fileName]!)) {
      const libAddr = libraries[contractName];
      if (!libAddr) throw new Error(`Missing library link: ${contractName}`);
      const addr = getAddress(libAddr).toLowerCase().slice(2);
      for (const { start, length } of linkReferences[fileName]![contractName]!) {
        const pos = 2 + start * 2;
        linked = linked.slice(0, pos) + addr + linked.slice(pos + length * 2);
      }
    }
  }
  return linked;
}

export type ForgeArtifactJson = {
  abi: InterfaceAbi;
  bytecode: {
    object: string;
    linkReferences?: LinkReferences;
  };
};

export function forgeToArtifact(forge: ForgeArtifactJson): ArtifactJson {
  return {
    abi: forge.abi,
    bytecode: forge.bytecode.object,
    linkReferences: forge.bytecode.linkReferences,
  };
}

export async function deployFromForgeArtifact(
  forge: ForgeArtifactJson,
  signer: Signer,
  args: unknown[] = [],
  libraries?: Record<string, string>,
) {
  return deployFromArtifact(forgeToArtifact(forge), signer, args, libraries);
}

export async function deployFromArtifact(
  artifact: ArtifactJson,
  signer: Signer,
  args: unknown[] = [],
  libraries?: Record<string, string>,
) {
  let bytecode = artifact.bytecode;
  if (artifact.linkReferences && Object.keys(artifact.linkReferences).length > 0) {
    if (!libraries) throw new Error("Artifact requires library linking");
    bytecode = linkLibraries(bytecode, artifact.linkReferences, libraries);
  }
  const factory = new ContractFactory(artifact.abi, bytecode, signer);
  const contract = await factory.deploy(...args);
  await contract.waitForDeployment();
  return contract;
}

export function connectFromArtifact(
  artifact: ArtifactJson,
  address: string,
  runner: ContractRunner,
): Contract {
  return new Contract(address, artifact.abi, runner);
}
