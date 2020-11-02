pragma solidity >=0.4.25 <0.7.0;

//using open zeppelin framework for smart contract security, cryptography and math functions
import "openzeppelin-solidity/contracts/cryptography/ECDSA.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";

contract TokenChannels {
    using SafeMath for uint256;
    using ECDSA for bytes32;

    /* Channel Statuses */
    enum ChannelStatus {OPEN, ON_CHALLENGE, CLOSED}

    /* Channel structure with token address and balances of both parties */
    struct Channel {
        bytes32 channelId;
        address tokenAddress;
        address partyAddress;
        address counterPartyAddress;
        uint256 partyBalance;
        uint256 counterPartyBalance;
        uint nonce;
        uint closeTime;
        uint challengePeriod;
        ChannelStatus status;
    }

    /* Mapping channelId to channels */
    mapping(bytes32 => Channel) public channels;

    /* Smart Contract Events */
    event ChannelOpened(bytes32 channelId);
    event CounterPartyJoined(bytes32 channelId);
    event ChannelOnChallenge(bytes32 channelId);
    event ChannelChallenged(bytes32 channelId);
    event ChannelClosed(bytes32 channelId);

    /* Smart Contract Function Modifiers */

    // check that channel is valid and exists with valid id
    modifier validChannel(bytes32 id) {
        require(channels[id].channelId != 0, "No channel with that channelId exists.");
        _;
    }

    // ensure that only channel parties can transact
    modifier onlyParties(bytes32 id) {
        require(
            msg.sender == channels[id].partyAddress || msg.sender == channels[id].counterPartyAddress,
            "You are not a participant in this channel."
        );
        _;
    }
    
    // check if channel is still open
    modifier isOpen(bytes32 id) {
        require(channels[id].status == ChannelStatus.OPEN, "The channel should be opened.");
        _;
    }

    // check if channel status is not closed
    modifier notClosed(bytes32 id) {
        require(
            channels[id].status != ChannelStatus.CLOSED,
            "The channel shouldn't not be closed."
        );
        _;
    }

    // check if channel is in challenge period
    modifier isOnChallenge(bytes32 id) {
        require(
            channels[id].status == ChannelStatus.ON_CHALLENGE,
            "The channel should be on challenge."
        );
        _;
    }

    // check if channel challenge period is not over
    modifier isDuringChallengePeriod(bytes32 id) {
        Channel memory channel = channels[id];
        bool challengeWasOver = now > channel.closeTime.add(channel.challengePeriod);
        require(!challengeWasOver, "The challenge period was over.");
        _;
    }

    // check if channel challenge period is over
    modifier challengePeriodWasOver(bytes32 id) {
        Channel memory channel = channels[id];
        bool challengeWasOver = now > channel.closeTime.add(channel.challengePeriod);
        require(challengeWasOver, "The challenge period should be over.");
        _;
    }

    
    /* Public functions */

    /**
   * Open a new channel. That contract should be approved by the sender to transfer on his behalf
   *
   * @param tokenAddress        The address of the token contract
   * @param counterPartyAddress The public address of the counter party
   * @param amount              The amount of tokens to deposit with the channel contract (cannot be zero)
   * @param challengePeriod     An optional challenge period for either party to close the channel
   */
    function open(
        address tokenAddress,
        address counterPartyAddress,
        uint256 amount,
        uint challengePeriod
    ) public {
        address partyAddress = msg.sender;

        require(partyAddress != counterPartyAddress, "You cannot create a channel with yourself.");
        require(amount != 0, "You cannot create a payment channel without tokens.");

        bytes32 channelId = keccak256(
            abi.encodePacked(tokenAddress, partyAddress, counterPartyAddress, block.number)
        );

        
        // Test to ensure that the channelId does not already exist
        require(channels[channelId].channelId == 0, "the channelId already exists.");

        Channel memory channel = Channel(
            channelId,
            tokenAddress,
            partyAddress,
            counterPartyAddress,
            amount, // partyBalance
            0, // counterPartyBalance
            0, // nonce
            0, // closeTime
            challengePeriod,
            ChannelStatus.OPEN // status
        );

        // transfer tokens from participants address to channel contract
        receiveTokens(channel.tokenAddress, partyAddress, amount);

        // map the channelId to the channel details
        channels[channelId] = channel;

        emit ChannelOpened(channelId);
    }

    /**
   * Allow counter party to join to an existing channel. 
   * The token contract should be approved by the msg.sender or counter party to transfer the specified
   * token amount on their behalf
   *
   * @param channelId   The channelId
   * @param amount      The token amount to deposit (can be zero)
   */
    function join(bytes32 channelId, uint256 amount)
        public
        validChannel(channelId)
        isOpen(channelId)
    {
        address counterPartyAddress = msg.sender;

        Channel storage channel = channels[channelId];

        // check that msg.sender has been specified as the counter party when the channel was created
        require(
            channel.counterPartyAddress == counterPartyAddress,
            "The channel creator did not specify you as the counter party. Check with them off-chain"
        );

        require(channel.counterPartyBalance == 0, "You cannot join to the channel twice.");

        require(amount >= 0, "Incorrect amount.");

        receiveTokens(channel.tokenAddress, counterPartyAddress, amount);

        channel.counterPartyBalance = amount;

        emit CounterPartyJoined(channelId);
    }

    /**
   * Close a channel
   *
   * @param channelId               Channel ID
   * @param nonce                   Sequence number
   * @param partyBalance            The final balance of the party
   * @param counterPartyBalance     The final balance of the counter party
   * @param partySignature          Last state of the channel signed by the party
   * @param counterPartySignature   Last state of the channel signed by the counter party
   */
    function close(
        bytes32 channelId,
        uint nonce,
        uint256 partyBalance,
        uint256 counterPartyBalance,
        bytes memory partySignature,
        bytes memory counterPartySignature
    ) public onlyParties(channelId) validChannel(channelId) isOpen(channelId) {
        verifyReceiptSignatures(
            channelId,
            nonce,
            partyBalance,
            counterPartyBalance,
            partySignature,
            counterPartySignature
        );

        updateReceipt(channelId, nonce, partyBalance, counterPartyBalance);

        Channel memory channel = channels[channelId];
        bool channelHasNoChallengePeriod = channel.challengePeriod == 0;

        if (channelHasNoChallengePeriod) {
            distributeFunds(channelId);
        } else {
            emit ChannelOnChallenge(channelId);
        }
    }

    /**
   * During the challenge period, either party can submit a proof that contains
   * a higher nonce
   *
   * @param channelId               Channel ID
   * @param nonce                   Sequence number
   * @param partyBalance            The final balance of the party
   * @param counterPartyBalance     The final balance of the counter party
   * @param partySignature          Last state of the channel signed by the party
   * @param counterPartySignature   Last state of the channel signed by the counter party
   */
    function challenge(
        bytes32 channelId,
        uint nonce,
        uint256 partyBalance,
        uint256 counterPartyBalance,
        bytes memory partySignature,
        bytes memory counterPartySignature
    )
        public
        onlyParties(channelId)
        validChannel(channelId)
        isOnChallenge(channelId)
        isDuringChallengePeriod(channelId)
    {
        Channel memory channel = channels[channelId];

        require(nonce > channel.nonce, "The nonce should be greater than the last.");

        verifyReceiptSignatures(
            channelId,
            nonce,
            partyBalance,
            counterPartyBalance,
            partySignature,
            counterPartySignature
        );

        updateReceipt(channelId, nonce, partyBalance, counterPartyBalance);
        emit ChannelChallenged(channelId);
    }

    /**
   * Redeem funds based on the last receipt
   *
   * @param channelId   Channel ID
   */
    function redeem(bytes32 channelId)
        public
        onlyParties(channelId)
        validChannel(channelId)
        isOnChallenge(channelId)
        challengePeriodWasOver(channelId)
    {
        distributeFunds(channelId);
    }

    //
    // Internal functions
    //

    /**
   * Transfer tokens from a participants address to the channel contract
   *
   * @param tokenAddress            The address of the ERC20 token contract
   * @param from                    The address of the owner of the funds
   * @param amount                  The value of the transfer (No transfer will be made if zero)
   */
    function receiveTokens(address tokenAddress, address from, uint256 amount) internal {
        if (amount > 0) {
            ERC20 token = ERC20(tokenAddress);
            require(token.transferFrom(from, address(this), amount), "Token transfer with error.");
        }
    }

    /**
   * Transfer tokens to a participant from the channel contract
   *
   * @param token       The ERC20 token object
   * @param to          The address of the beneficiary of the funds
   * @param amount      The value of the transfer (No transfer will be made if zero)
   */
    function sendTokens(ERC20 token, address to, uint256 amount) internal {
        if (amount > 0) {
            require(token.transfer(to, amount), "Token transfer with error.");
        }
    }

    /**
   * Check the signatures of channel parcipants
   *
   * @param channelId               Channel ID
   * @param nonce                   Sequence number
   * @param partyBalance            The final balance of the party
   * @param counterPartyBalance     The final balance of the counter party
   * @param partySignature          Last state of the channel signed by the party
   * @param counterPartySignature   Last state of the channel signed by the counter party
   */
    function verifyReceiptSignatures(
        bytes32 channelId,
        uint nonce,
        uint256 partyBalance,
        uint256 counterPartyBalance,
        bytes memory partySignature,
        bytes memory counterPartySignature
    ) internal view {
        Channel memory channel = channels[channelId];

        bytes32 stateHash = keccak256(
            abi.encodePacked(channelId, partyBalance, counterPartyBalance, nonce)
        );

        // check if a hash was signed by an address with hash, signature to check, address to check
        require(
            ecverify(stateHash, partySignature, channel.partyAddress),
            "The partySignature is invalid."
        );
        require(
            ecverify(stateHash, counterPartySignature, channel.counterPartyAddress),
            "The counterPartySignature is invalid."
        );
    }

    /**
   * Update channel receipt
   *
   * @param channelId               Channel ID
   * @param nonce                   Sequence number
   * @param partyBalance            The final balance of the party
   * @param counterPartyBalance     The final balance of the counter party
   */
    function updateReceipt(
        bytes32 channelId,
        uint nonce,
        uint256 partyBalance,
        uint256 counterPartyBalance
    ) internal {
        Channel storage channel = channels[channelId];

        require(
            partyBalance.add(counterPartyBalance) == channel.partyBalance.add(
                channel.counterPartyBalance
            ),
            "The total balances on/off chain do not match."
        );

        channel.nonce = nonce;
        channel.partyBalance = partyBalance;
        channel.counterPartyBalance = counterPartyBalance;
        if (channel.closeTime == 0) channel.closeTime = now;
        channel.status = ChannelStatus.ON_CHALLENGE;
    }

    /**
   * Transfer tokens to channel participants
   *
   * @param channelId   Channel ID
   */
    function distributeFunds(bytes32 channelId) internal notClosed(channelId) {
        Channel storage channel = channels[channelId];
        channel.status = ChannelStatus.CLOSED;
        ERC20 token = ERC20(channel.tokenAddress);

        sendTokens(token, channel.partyAddress, channel.partyBalance);
        sendTokens(token, channel.counterPartyAddress, channel.counterPartyBalance);

        emit ChannelClosed(channelId);
    }

    /**
   * Check if a hash was signed by an address
   * Note: That function was tested using signatures by web3.eth.sign()
   *
   * @param hash        Hash data
   * @param signature   Signature to check
   * @param signer      Signer to check
   */
    function ecverify(bytes32 hash, bytes memory signature, address signer)
        internal
        pure
        returns (bool b)
    {
        bytes32 ethHash = hash.toEthSignedMessageHash();
        return ethHash.recover(signature) == signer;
    }

}