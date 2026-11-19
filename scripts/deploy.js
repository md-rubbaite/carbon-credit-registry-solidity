// Usage: npx hardhat run scripts/deploy.js --network <network>
// Hand DEFAULT_ADMIN_ROLE to a multisig/timelock immediately after deployment.
const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  const admin = process.env.REGISTRY_ADMIN || deployer.address;
  const registry = await (await ethers.getContractFactory("CarbonCreditRegistry")).deploy(admin, "ipfs://registry/{id}.json");
  await registry.waitForDeployment();
  console.log(`CarbonCreditRegistry deployed to ${await registry.getAddress()} (admin ${admin})`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
