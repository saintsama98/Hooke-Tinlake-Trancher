# Security

Hooke-Tinlake-Trancher is a research build. It has not been audited, it is not deployed, and there is no bug bounty.

## Reporting

Please report a vulnerability privately by email to adiiiresearch@gmail.com or biradaraditya9712@gmail.com rather than in a public issue. Include the affected contract, the steps to reproduce (a Foundry test is ideal), and the impact you expect.

## Scope

The contracts under `src/` and the deployment wiring in `script/LenderDeployer.s.sol`. Issues that also exist in upstream Centrifuge Tinlake are welcome, but note that Tinlake itself is maintained by Centrifuge. The NAV feed is a seam with a test mock behind it, so valuation is out of scope unless the bug is in how the pool consumes it.
