pragma solidity ^0.4.18;

import './SafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/ICustomers.sol';
import './interfaces/ISTRegistrar.sol';
import './interfaces/ICompliance.sol';
import './interfaces/ITemplate.sol';
import './STO20.sol';

/**
 * @title SecurityToken
 * @dev Contract (A Blueprint) that contains the functionalities of the security token
 */

contract SecurityToken is IERC20 {

    using SafeMath for uint256;

    string public VERSION = "1";

    IERC20 public POLY;                                               // Instance of the POLY token contract

    ICompliance public PolyCompliance;                                // Instance of the Compliance contract

    ITemplate public Template;                                        // Instance of the Template contract

    ICustomers public PolyCustomers;                                  // Instance of the Customers contract

    STO20 public STO;

    // ERC20 Fields
    string public name;                                               // Name of the security token
    uint8 public decimals;                                            // Decimals for the security token it should be 0 as standard
    string public symbol;                                             // Symbol of the security token
    address public owner;                                             // Address of the owner of the security token
    uint256 public totalSupply;                                       // Total number of security token generated
    mapping(address => mapping(address => uint256)) allowed;          // Mapping as same as in ERC20 token
    mapping(address => uint256) balances;                             // Array used to store the balances of the security token holders

    // Template
    address public delegate;                                          // Address who create the template
    bytes32 public merkleRoot;                                        //
    address public KYC;                                               // Address of the KYC provider which aloowed the roles and jurisdictions in the template

    // Security token shareholders
    struct Shareholder {                                              // Structure that contains the data of the shareholders
        address verifier;                                             // verifier - address of the KYC oracle
        bool allowed;                                                 // allowed - whether the shareholder is allowed to transfer or recieve the security token
        uint8 role;                                                   // role - role of the shareholder {1,2,3,4}
    }

    mapping(address => Shareholder) public shareholders;              // Mapping that holds the data of the shareholder corresponding to investor address

    // STO
    bool public isSTOProposed = false;
    bool public isTemplateSet = false;
    bool public hasOfferingStarted = false;
    uint256 public maxPoly;

    // The start and end time of the STO
    uint256 public startSTO;                                          // Timestamp when Security Token Offering will be start
    uint256 public endSTO;                                            // Timestamp when Security Token Offering contract will ends

    // POLY allocations
    struct Allocation {                                               // Structure that contains the allocation of the POLY for stakeholders
        uint256 amount;                                               // stakeholders - delegate, issuer(owner), auditor
        uint256 vestingPeriod;
        uint8 quorum;
        uint256 yayVotes;
        uint256 yayPercent;
        bool frozen;
    }
    mapping(address => mapping(address => bool)) public voted;               // Voting mapping
    mapping(address => Allocation) public allocations;                       // Mapping that contains the data of allocation corresponding to stakeholder address

	   // Security Token Offering statistics
    mapping(address => uint256) public contributedToSTO;                     // Mapping for tracking the POLY contribution by the contributor
    uint256 public tokensIssuedBySTO = 0;                             // Flag variable to track the security token issued by the offering contract

    // Notifications
    event LogTemplateSet(address indexed _delegateAddress, address indexed _template, address indexed _KYC);
    event LogUpdatedComplianceProof(bytes32 _merkleRoot, bytes32 _complianceProofHash);
    event LogSetSTOContract(address indexed _STO, address indexed _auditor, uint256 _startTime, uint256 _endTime);
    event LogNewWhitelistedAddress(address indexed _KYC, address indexed _shareholder, uint8 _role);
    event LogNewBlacklistedAddress(address indexed _shareholder);
    event LogVoteToFreeze(address indexed _recipient, uint256 _yayPercent, uint8 _quorum, bool _frozen);
    event LogTokenIssued(address indexed _contributor, uint256 _stAmount, uint256 _polyContributed, uint256 _timestamp);

    //Modifiers
    modifier onlyOwner() {
        require (msg.sender == owner);
        _;
    }

    modifier onlyDelegate() {
        require (msg.sender == delegate);
        _;
    }

    modifier onlyOwnerOrDelegate() {
        require (msg.sender == delegate || msg.sender == owner);
        _;
    }

    modifier onlySTO() {
        require (msg.sender == address(STO));
        _;
    }

    modifier onlyShareholder() {
        require (shareholders[msg.sender].allowed);
        _;
    }

    /**
     * @dev Set default security token parameters
     * @param _name Name of the security token
     * @param _ticker Ticker name of the security
     * @param _totalSupply Total amount of tokens being created
     * @param _owner Ethereum address of the security token owner
     * @param _maxPoly Amount of maximum poly issuer want to raise
     * @param _lockupPeriod Length of time raised POLY will be locked up for dispute
     * @param _quorum Percent of initial investors required to freeze POLY raise
     * @param _polyTokenAddress Ethereum address of the POLY token contract
     * @param _polyCustomersAddress Ethereum address of the PolyCustomers contract
     * @param _polyComplianceAddress Ethereum address of the PolyCompliance contract
     */
    function SecurityToken(
        string _name,
        string _ticker,
        uint256 _totalSupply,
        uint8 _decimals,
        address _owner,
        uint256 _maxPoly,
        uint256 _lockupPeriod,
        uint8 _quorum,
        address _polyTokenAddress,
        address _polyCustomersAddress,
        address _polyComplianceAddress
    ) public
    {
        decimals = _decimals;
        name = _name;
        symbol = _ticker;
        owner = _owner;
        maxPoly = _maxPoly;
        totalSupply = _totalSupply;
        balances[_owner] = _totalSupply;
        POLY = IERC20(_polyTokenAddress);
        PolyCustomers = ICustomers(_polyCustomersAddress);
        PolyCompliance = ICompliance(_polyComplianceAddress);
        allocations[owner] = Allocation(0, _lockupPeriod, _quorum, 0, 0, false);
        Transfer(0x0, _owner, _totalSupply);
    }

    /* function initialiseBalances(uint256) */

    /**
     * @dev `selectTemplate` Select a proposed template for the issuance
     * @param _templateIndex Array index of the delegates proposed template
     * @return bool success
     */
    function selectTemplate(uint8 _templateIndex) public onlyOwner returns (bool success) {
        require(!isTemplateSet);
        isTemplateSet = true;
        address _template = PolyCompliance.getTemplateByProposal(this, _templateIndex);
        require(_template != address(0));
        Template = ITemplate(_template);
        var (_fee, _quorum, _vestingPeriod, _delegate, _KYC) = Template.getUsageDetails();
        require(POLY.balanceOf(this) >= _fee);
        allocations[_delegate] = Allocation(_fee, _vestingPeriod, _quorum, 0, 0, false);
        delegate = _delegate;
        KYC = _KYC;
        PolyCompliance.updateTemplateReputation(_template, _templateIndex);
        LogTemplateSet(_delegate, _template, _KYC);
        return true;
    }

    /**
     * @dev Update compliance proof hash for the issuance
     * @param _newMerkleRoot New merkle root hash of the compliance Proofs
     * @param _merkleRoot Compliance Proof hash
     * @return bool success
     */
    function updateComplianceProof(
        bytes32 _newMerkleRoot,
        bytes32 _merkleRoot
    ) public onlyOwnerOrDelegate returns (bool success)
    {
        merkleRoot = _newMerkleRoot;
        LogUpdatedComplianceProof(merkleRoot, _merkleRoot);
        return true;
    }

    /**
     * @dev `selectOfferingProposal` Select an security token offering proposal for the issuance
     * @param _offeringProposalIndex Array index of the STO proposal
     * @return bool success
     */
    function selectOfferingProposal (uint8 _offeringProposalIndex) public onlyDelegate returns (bool success) {
        require(!isSTOProposed);
        var (_stoContract, _auditor, _vestingPeriod, _quorum, _fee) = PolyCompliance.getOfferingByProposal(this, _offeringProposalIndex);
        require(_stoContract != address(0));
        require(merkleRoot != 0x0);
        require(delegate != address(0));
        require(POLY.balanceOf(this) >= allocations[delegate].amount.add(_fee));
        STO = STO20(_stoContract);
        require(STO.startTime() > now && STO.endTime() > STO.startTime());
        allocations[_auditor] = Allocation(_fee, _vestingPeriod, _quorum, 0, 0, false);
        shareholders[_stoContract] = Shareholder(this, true, 5);
        startSTO = STO.startTime();
        endSTO = STO.endTime();
        isSTOProposed = true;
        PolyCompliance.updateOfferingReputation(_stoContract, _offeringProposalIndex);
        LogSetSTOContract(_stoContract, _auditor, startSTO, endSTO);
        return true;
    }

    /**
     * @dev Start the offering by sending all the tokens to STO contract
     * @return bool
     */
    function startOffering() onlyOwner external returns (bool success) {
        require(isSTOProposed);
        require(!hasOfferingStarted);
        uint256 tokenAmount = this.balanceOf(msg.sender);
        require(tokenAmount == totalSupply);
        balances[STO] = balances[STO].add(tokenAmount);
        balances[msg.sender] = balances[msg.sender].sub(tokenAmount);
        hasOfferingStarted = true;
        Transfer(owner, STO, tokenAmount);
        return true;
    }

    /**
     * @dev Add a verified address to the Security Token whitelist
     * The Issuer can add an address to the whitelist by themselves by
     * creating their own KYC provider and using it to verify the accounts
     * they want to add to the whitelist.
     * @param _whitelistAddress Address attempting to join ST whitelist
     * @return bool success
     */
    function addToWhitelist(address _whitelistAddress) onlyOwner public returns (bool success) {
        var (countryJurisdiction, divisionJurisdiction, accredited, role, expires) = PolyCustomers.getCustomer(KYC, _whitelistAddress);
        require(expires > now);
        require(Template.checkTemplateRequirements(countryJurisdiction, divisionJurisdiction, accredited, role));
        shareholders[_whitelistAddress] = Shareholder(KYC, true, role);
        LogNewWhitelistedAddress(KYC, _whitelistAddress, role);
        return true;
    }

    function addToWhitelistMulti(address[] _whitelistAddresses) onlyOwner public {
      for (uint256 i = 0; i < _whitelistAddresses.length; i++) {
        require(addToWhitelist(_whitelistAddresses[i]));
      }
    }

    function addToBlacklistMulti(address[] _blacklistAddresses) onlyOwner public {
      for (uint256 i = 0; i < _blacklistAddresses.length; i++) {
        require(addToBlacklist(_blacklistAddresses[i]));
      }
    }

    /**
     * @dev Add a verified address to the Security Token blacklist
     * @param _blacklistAddress Address being added to the blacklist
     * @return bool success
     */
    function addToBlacklist(address _blacklistAddress) onlyOwner public returns (bool success) {
        require(shareholders[_blacklistAddress].allowed);
        shareholders[_blacklistAddress].allowed = false;
        LogNewBlacklistedAddress(_blacklistAddress);
        return true;
    }

    /**
     * @dev Allow POLY allocations to be withdrawn by owner, delegate, and the STO auditor at appropriate times
     * @return bool success
     */
    function withdrawPoly() public returns (bool success) {
  	    if (delegate == address(0)) {
          return POLY.transfer(owner, POLY.balanceOf(this));
        }
        require(now > endSTO.add(allocations[msg.sender].vestingPeriod));
        require(!allocations[msg.sender].frozen);
        require(allocations[msg.sender].amount > 0);
        require(POLY.transfer(msg.sender, allocations[msg.sender].amount));
        allocations[msg.sender].amount = 0;
        return true;
    }

    /**
     * @dev Vote to freeze the fee of a certain network participant
     * @param _recipient The fee recipient being protested
     * @return bool success
     */
    function voteToFreeze(address _recipient) public onlyShareholder returns (bool success) {
        require(delegate != address(0));
        require(now > endSTO);
        require(now < endSTO.add(allocations[_recipient].vestingPeriod));
        require(!voted[msg.sender][_recipient]);
        voted[msg.sender][_recipient] = true;
        allocations[_recipient].yayVotes = allocations[_recipient].yayVotes.add(contributedToSTO[msg.sender]);
        allocations[_recipient].yayPercent = allocations[_recipient].yayVotes.mul(100).div(allocations[owner].amount);
        if (allocations[_recipient].yayPercent >= allocations[_recipient].quorum) {
          allocations[_recipient].frozen = true;
        }
        LogVoteToFreeze(_recipient, allocations[_recipient].yayPercent, allocations[_recipient].quorum, allocations[_recipient].frozen);
        return true;
    }

	/**
     * @dev `issueSecurityTokens` is used by the STO to keep track of STO investors
     * @param _contributor The address of the person whose contributing
     * @param _amountOfSecurityTokens The amount of ST to pay out.
     * @param _polyContributed The amount of POLY paid for the security tokens.
     */
    function issueSecurityTokens(address _contributor, uint256 _amountOfSecurityTokens, uint256 _polyContributed) public onlySTO returns (bool success) {
        // Check whether the offering active or not
        require(hasOfferingStarted);
        // The _contributor being issued tokens must be in the whitelist
        require(shareholders[_contributor].allowed);
        // Tokens may only be issued while the STO is running
        require(now >= startSTO && now <= endSTO);
        // In order to issue the ST, the _contributor first pays in POLY
        require(POLY.transferFrom(_contributor, this, _polyContributed));
        // ST being issued can't be higher than the totalSupply
        require(tokensIssuedBySTO.add(_amountOfSecurityTokens) <= totalSupply);
        // POLY contributed can't be higher than maxPoly set by STO
        require(maxPoly >= allocations[owner].amount.add(_polyContributed));
        // Update ST balances (transfers ST from STO to _contributor)
        balances[STO] = balances[STO].sub(_amountOfSecurityTokens);
        balances[_contributor] = balances[_contributor].add(_amountOfSecurityTokens);
        // ERC20 Transfer event
        Transfer(STO, _contributor, _amountOfSecurityTokens);
        // Update the amount of tokens issued by STO
        tokensIssuedBySTO = tokensIssuedBySTO.add(_amountOfSecurityTokens);
        // Update the amount of POLY a contributor has contributed and allocated to the owner
        contributedToSTO[_contributor] = contributedToSTO[_contributor].add(_polyContributed);
        allocations[owner].amount = allocations[owner].amount.add(_polyContributed);
        LogTokenIssued(_contributor, _amountOfSecurityTokens, _polyContributed, now);
        return true;
    }

    // Get token details
    function getTokenDetails() view public returns (address, address, bytes32, address, address) {
        return (Template, delegate, merkleRoot, STO, KYC);
    }

/////////////////////////////////////////////// Customized ERC20 Functions ////////////////////////////////////////////////////////////

    /**
     * @dev Trasfer tokens from one address to another
     * @param _to Ethereum public address to transfer tokens to
     * @param _value Amount of tokens to send
     * @return bool success
     */
    function transfer(address _to, uint256 _value) public returns (bool success) {
        if (shareholders[_to].allowed && shareholders[msg.sender].allowed && balances[msg.sender] >= _value) {
            balances[msg.sender] = balances[msg.sender].sub(_value);
            balances[_to] = balances[_to].add(_value);
            Transfer(msg.sender, _to, _value);
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Allows contracts to transfer tokens on behalf of token holders
     * @param _from Address to transfer tokens from
     * @param _to Address to send tokens to
     * @param _value Number of tokens to transfer
     * @return bool success
     */
    function transferFrom(address _from, address _to, uint256 _value) public returns (bool success) {
        if (shareholders[_to].allowed && shareholders[_from].allowed && balances[_from] >= _value && allowed[_from][msg.sender] >= _value) {
            uint256 _allowance = allowed[_from][msg.sender];
            balances[_from] = balances[_from].sub(_value);
            allowed[_from][msg.sender] = _allowance.sub(_value);
            balances[_to] = balances[_to].add(_value);
            Transfer(_from, _to, _value);
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev `balanceOf` used to get the balance of shareholders
     * @param _owner The address from which the balance will be retrieved
     * @return The balance
     */
    function balanceOf(address _owner) public constant returns (uint256 balance) {
        return balances[_owner];
    }

    /**
     * @dev Approve transfer of tokens manually
     * @param _spender Address to approve transfer to
     * @param _value Amount of tokens to approve for transfer
     * @return bool success
     */
    function approve(address _spender, uint256 _value) public returns (bool success) {
        allowed[msg.sender][_spender] = _value;
        Approval(msg.sender, _spender, _value);
        return true;
    }

    /**
     * @dev Use to get the allowance provided to the spender
     * @param _owner The address of the account owning tokens
     * @param _spender The address of the account able to transfer the tokens
     * @return Amount of remaining tokens allowed to spent
     */
    function allowance(address _owner, address _spender) public constant returns (uint256 remaining) {
        return allowed[_owner][_spender];
    }
}
