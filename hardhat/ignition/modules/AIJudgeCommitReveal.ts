import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("AIJudgeCommitRevealModule", (m) => {
  const aiJudge = m.contract("AIJudgeCommitReveal");
  return { aiJudge };
});
