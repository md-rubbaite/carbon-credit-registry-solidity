const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

describe("CarbonCreditRegistry", function () {
  const REPORT = ethers.id("verification-report-2025-Q4.pdf");

  async function deploy() {
    const [admin, registrar, verifier, developer, buyer, stranger] = await ethers.getSigners();
    const Registry = await ethers.getContractFactory("CarbonCreditRegistry");
    const registry = await Registry.deploy(admin.address, "ipfs://registry/{id}.json");

    await registry.grantRole(await registry.REGISTRAR_ROLE(), registrar.address);
    await registry.grantRole(await registry.VERIFIER_ROLE(), verifier.address);
    await registry.connect(registrar).registerProject(developer.address, "VM0047 ARR", "ipfs://pdd/forest-1");

    return { registry, admin, registrar, verifier, developer, buyer, stranger };
  }

  async function issued() {
    const ctx = await deploy();
    await ctx.registry.connect(ctx.verifier).issueBatch(1, 2025, 1_000, REPORT);
    return ctx;
  }

  describe("issuance", function () {
    it("mints a verified batch to the project developer", async function () {
      const { registry, verifier, developer } = await loadFixture(deploy);

      await expect(registry.connect(verifier).issueBatch(1, 2025, 1_000, REPORT))
        .to.emit(registry, "BatchIssued")
        .withArgs(1, 1, 2025, 1_000, REPORT, verifier.address);

      expect(await registry.balanceOf(developer.address, 1)).to.equal(1_000);
      expect(await registry.outstanding(1)).to.equal(1_000);
    });

    it("rejects reuse of a verification report (no double issuance)", async function () {
      const { registry, verifier } = await loadFixture(issued);

      await expect(registry.connect(verifier).issueBatch(1, 2025, 500, REPORT))
        .to.be.revertedWithCustomError(registry, "ReportAlreadyUsed");
    });

    it("only verifiers can issue", async function () {
      const { registry, stranger } = await loadFixture(deploy);

      await expect(registry.connect(stranger).issueBatch(1, 2025, 1, REPORT))
        .to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount");
    });

    it("a verifier cannot certify its own project", async function () {
      const { registry, registrar, verifier } = await loadFixture(deploy);
      await registry.connect(registrar).registerProject(verifier.address, "VM0047", "ipfs://pdd/self");

      await expect(registry.connect(verifier).issueBatch(2, 2025, 10, ethers.id("other")))
        .to.be.revertedWithCustomError(registry, "VerifierIsDeveloper");
    });

    it("rejects inactive projects, zero amounts and future vintages", async function () {
      const { registry, registrar, verifier } = await loadFixture(deploy);

      await expect(registry.connect(verifier).issueBatch(1, 2025, 0, REPORT)).to.be.revertedWithCustomError(registry, "InvalidAmount");
      await expect(registry.connect(verifier).issueBatch(1, 2999, 1, REPORT)).to.be.revertedWithCustomError(registry, "InvalidVintage");

      await registry.connect(registrar).setProjectActive(1, false);
      await expect(registry.connect(verifier).issueBatch(1, 2025, 1, REPORT)).to.be.revertedWithCustomError(registry, "ProjectInactive");
    });
  });

  describe("transfer and retirement", function () {
    it("retiring burns the credits and records a public certificate", async function () {
      const { registry, developer, buyer } = await loadFixture(issued);
      await registry.connect(developer).safeTransferFrom(developer.address, buyer.address, 1, 300, "0x");

      await expect(registry.connect(buyer).retire(1, 250, "Acme Ltd", "FY2026 Scope 1 offset"))
        .to.emit(registry, "CreditsRetired")
        .withArgs(0, 1, buyer.address, 250, "Acme Ltd", "FY2026 Scope 1 offset");

      expect(await registry.balanceOf(buyer.address, 1)).to.equal(50);
      expect(await registry.outstanding(1)).to.equal(750);
      const cert = await registry.retirement(0);
      expect(cert.beneficiary).to.equal("Acme Ltd");
      expect(cert.amount).to.equal(250);
    });

    it("cannot retire more than you hold, so a tonne cannot be claimed twice", async function () {
      const { registry, developer, buyer } = await loadFixture(issued);
      await registry.connect(developer).retire(1, 1_000, "Developer", "all");

      await expect(registry.connect(developer).retire(1, 1, "Developer", "again"))
        .to.be.revertedWithCustomError(registry, "ERC1155InsufficientBalance");
      await expect(registry.connect(developer).safeTransferFrom(developer.address, buyer.address, 1, 1, "0x"))
        .to.be.revertedWithCustomError(registry, "ERC1155InsufficientBalance");
    });

    it("requires a beneficiary for retirement", async function () {
      const { registry, developer } = await loadFixture(issued);

      await expect(registry.connect(developer).retire(1, 1, "", "x")).to.be.revertedWithCustomError(registry, "EmptyBeneficiary");
    });
  });

  describe("incident response", function () {
    it("pausing freezes issuance, transfers and retirement", async function () {
      const { registry, admin, verifier, developer, buyer } = await loadFixture(issued);
      await registry.connect(admin).pause();

      await expect(registry.connect(verifier).issueBatch(1, 2025, 1, ethers.id("r2"))).to.be.revertedWithCustomError(registry, "EnforcedPause");
      await expect(registry.connect(developer).safeTransferFrom(developer.address, buyer.address, 1, 1, "0x")).to.be.revertedWithCustomError(registry, "EnforcedPause");
      await expect(registry.connect(developer).retire(1, 1, "B", "r")).to.be.revertedWithCustomError(registry, "EnforcedPause");

      await registry.connect(admin).unpause();
      await registry.connect(developer).safeTransferFrom(developer.address, buyer.address, 1, 1, "0x");
      expect(await registry.balanceOf(buyer.address, 1)).to.equal(1);
    });
  });
});
