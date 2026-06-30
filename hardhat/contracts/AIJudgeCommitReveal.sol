// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function depositFor(address user, uint256 lockDuration) external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function lockUntil(address) external view returns (uint256);
}

/**
 * @title AIJudgeCommitReveal
 * @notice Privacy-preserving bounty judge using commit-reveal scheme.
 *
 * LIFECYCLE:
 *   1. Owner creates bounty with a deadline (submission phase end).
 *   2. Participants submit keccak256(answer ++ salt ++ msg.sender ++ bountyId)
 *      during the submission window — answer stays hidden on-chain.
 *   3. After deadline, participants reveal answer + salt.
 *      Contract verifies the hash matches; only valid reveals enter judging.
 *   4. Owner calls judgeAll() after reveal window closes.
 *      Ritual LLM evaluates all revealed answers in one batch call.
 *   5. Owner calls finalizeWinner() to pay out the winner.
 */
contract AIJudgeCommitReveal is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS   = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;
    uint256 public constant REVEAL_WINDOW     = 2 days;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    struct Commitment {
        bytes32 hash;
        bool    revealed;
        bool    valid;
    }

    struct Submission {
        address submitter;
        string  answer;
    }

    struct Bounty {
        address      owner;
        string       title;
        string       rubric;
        uint256      reward;
        uint256      deadline;
        bool         judged;
        bool         finalized;
        bytes        aiReview;
        uint256      winnerIndex;
        Commitment[] commitments;
        Submission[] submissions;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string  title,
        uint256 reward,
        uint256 deadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event RevealInvalid(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 deadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0,           "reward required");
        require(deadline > block.timestamp, "deadline must be future");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner       = msg.sender;
        bounty.title       = title;
        bounty.rubric      = rubric;
        bounty.reward      = msg.value;
        bounty.deadline    = deadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, deadline);
    }

    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.deadline, "submission phase closed");
        require(!bounty.judged,    "already judged");
        require(!bounty.finalized, "already finalized");
        require(
            bounty.commitments.length < MAX_SUBMISSIONS,
            "too many submissions"
        );
        require(commitment != bytes32(0), "empty commitment");

        for (uint256 i = 0; i < bounty.commitments.length; i++) {
            require(
                bounty.submissions[i].submitter != msg.sender,
                "already committed"
            );
        }

        uint256 idx = bounty.commitments.length;

        bounty.commitments.push(Commitment({
            hash:     commitment,
            revealed: false,
            valid:    false
        }));
        bounty.submissions.push(Submission({
            submitter: msg.sender,
            answer:    ""
        }));

        emit CommitmentSubmitted(bountyId, idx, msg.sender);
    }

    function revealAnswer(
        uint256        bountyId,
        string calldata answer,
        bytes32        salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.deadline,                         "reveal not open yet");
        require(block.timestamp <  bounty.deadline + REVEAL_WINDOW,         "reveal window closed");
        require(!bounty.judged,                                              "already judged");
        require(bytes(answer).length > 0,                                   "empty answer");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH,                  "answer too long");

        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < bounty.submissions.length; i++) {
            if (bounty.submissions[i].submitter == msg.sender) {
                idx = i;
                break;
            }
        }
        require(idx != type(uint256).max, "no commitment found");

        Commitment storage c = bounty.commitments[idx];
        require(!c.revealed, "already revealed");

        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );

        c.revealed = true;

        if (expected == c.hash) {
            c.valid = true;
            bounty.submissions[idx].answer = answer;
            emit AnswerRevealed(bountyId, idx, msg.sender);
        } else {
            emit RevealInvalid(bountyId, idx, msg.sender);
        }
    }

    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp >= bounty.deadline + REVEAL_WINDOW,
            "reveal window still open"
        );
        require(!bounty.judged,    "already judged");
        require(!bounty.finalized, "already finalized");

        uint256 validCount = 0;
        for (uint256 i = 0; i < bounty.commitments.length; i++) {
            if (bounty.commitments[i].valid) validCount++;
        }
        require(validCount > 0, "no valid reveals to judge");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged    = true;
        bounty.aiReview  = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged,    "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid winner index");
        require(
            bounty.commitments[winnerIndex].valid,
            "winner must have a valid reveal"
        );

        bounty.finalized   = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward  = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string  memory title,
            string  memory rubric,
            uint256 reward,
            uint256 deadline,
            uint256 revealDeadline,
            bool    judged,
            bool    finalized,
            uint256 submissionCount,
            uint256 validRevealCount,
            uint256 winnerIndex,
            bytes   memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];

        uint256 validCount = 0;
        for (uint256 i = 0; i < bounty.commitments.length; i++) {
            if (bounty.commitments[i].valid) validCount++;
        }

        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.deadline,
            bounty.deadline + REVEAL_WINDOW,
            bounty.judged,
            bounty.finalized,
            bounty.submissions.length,
            validCount,
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    function getCommitment(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes32 commitmentHash,
            bool    revealed,
            bool    valid
        )
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.commitments.length, "invalid index");

        return (
            bounty.submissions[index].submitter,
            bounty.commitments[index].hash,
            bounty.commitments[index].revealed,
            bounty.commitments[index].valid
        );
    }

    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, string memory answer, bool revealed, bool valid)
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.submissions.length, "invalid index");

        Commitment storage c = bounty.commitments[index];

        string memory visibleAnswer = c.valid ? bounty.submissions[index].answer : "";

        return (
            bounty.submissions[index].submitter,
            visibleAnswer,
            c.revealed,
            c.valid
        );
    }
}
