// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Pausable.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./owner/Operator.sol";
import "./lib/SafeMath8.sol";
import "./interfaces/ITomb.sol";
import "./interfaces/ITaxOfficeV2.sol";
import "./interfaces/IOracle.sol";

contract WrappedTomb is ERC20Burnable, ERC20Pausable, Operator {
    using SafeMath8 for uint8;
    using SafeMath for uint256;

    // Error Code: No error.
    uint256 public constant ERR_NO_ERROR = 0x0;
    // Error Code: Non-zero value expected to perform the function.
    uint256 public constant ERR_INVALID_ZERO_VALUE = 0x01;

    ITomb public tomb = ITomb(0x6c021Ae822BEa943b2E66552bDe1D2696a53fbB7);
    ITaxOfficeV2 public taxOffice;
    IOracle public oracle;

    // Is transfer tax enabled
    bool public taxEnabled;
    // Address which gathers the tax if tax burn is disabled
    address public taxCollectorAddress;
    // Tax rate when autocalculating is disabled
    uint256 public staticTaxRate;
    // Is autocalculating tax rate enabled
    bool public autoCalculateTax;

    // Senders that are not taxed when using transferFrom method
    mapping(address => bool) sendersExcludedFromTax;
    // Recipients that are not taxed when using transferFrom method
    mapping(address => bool) recipientsExcludedFromTax;

    // Senders that are taxed when using transfer method
    mapping(address => bool) sendersIncludedInTax;
    // Recipients that are taxed when using transfer method
    mapping(address => bool) recipientsIncludedInTax;

    /* EVENTS */
    event TaxOfficeChanged(address indexed executor, address oldAddress, address newAddress);
    event OracleChanged(address indexed executor, address oldAddress, address newAddress);
    event TaxCollectorAddressChanged(address indexed executor, address oldAddress, address newAddress);
    event StaticTaxRateChanged(address indexed executor, uint256 oldTaxRate, uint256 newTaxRate);
    event AutoCalculateTaxChanged(address indexed executor, bool newState);
    event TaxEnabledChanged(address indexed executor, bool newState);

    // Create instance of WTOMB
    constructor(
        address _taxOffice,
        address _oracle,
        address _taxCollectorAddress
    ) public ERC20("Wrapped TOMB", "WTOMB") {
        taxOffice = ITaxOfficeV2(_taxOffice);
        oracle = IOracle(_oracle);

        taxCollectorAddress = _taxCollectorAddress;

        autoCalculateTax = true;
        staticTaxRate = 0;
    }

    // Wrap TOMB into WTOMB
    function deposit(uint256 _amount) public whenNotPaused returns (uint256) {
        if (_amount == 0) {
            return ERR_INVALID_ZERO_VALUE;
        }

        taxOffice.taxFreeTransferFrom(msg.sender, address(this), _amount);
        _mint(msg.sender, _amount);

        return ERR_NO_ERROR;
    }

    // Unwrap TOMB from WTOMB
    function withdraw(uint256 _amount) public whenNotPaused returns (uint256) {
        if (_amount == 0) {
            return ERR_INVALID_ZERO_VALUE;
        }

        _burn(msg.sender, _amount);
        tomb.transfer(msg.sender, _amount);

        return ERR_NO_ERROR;
    }

    /* INTERNAL TAX METHODS */

    // Retrieves the current TOMB price from an Oracle
    function _getTombPrice() internal view returns (uint256 _tombPrice) {
        try oracle.consult(address(this), 1e18) returns (uint144 _price) {
            return uint256(_price);
        } catch {
            revert("Wrapped Tomb: failed to fetch TOMB price from Oracle");
        }
    }

    // Chooses the tax rate to be applied
    function _getTaxRate(uint256 _tombPrice) internal view returns (uint256) {
        if (!taxEnabled) {
            return 0;
        } else if (autoCalculateTax) {
            // Retrieve tax tiers for autocalculated tax from the TOMB contract
            uint256[] memory _taxTiersTwaps = tomb.taxTiersTwaps();
            uint256[] memory _taxTiersRates = tomb.taxTiersRates();
            for (uint8 tierId = uint8(_taxTiersTwaps.length).sub(1); tierId >= 0; --tierId) {
                if (_tombPrice >= _taxTiersTwaps[tierId]) {
                    require(_taxTiersRates[tierId] < 10000, "tax equal or bigger to 100%");
                    return _taxTiersRates[tierId];
                }
            }
        } else {
            // Use static tax rate when the autocalculation is disabled
            return staticTaxRate;
        }
    }

    // Retrieves the tax burn threshold from the TOMB contract
    function _getBurnThreshold() internal view returns (uint256) {
        return tomb.burnThreshold();
    }

    // Retrieves the tax parameters
    function _getTaxParams() internal view returns (uint256 _currentTaxRate, bool _burnTax) {
        uint256 _currentTombPrice = _getTombPrice();
        _currentTaxRate = _getTaxRate(_currentTombPrice);
        uint256 _burnThreshold = _getBurnThreshold();

        _burnTax = false;
        if (_currentTombPrice < _burnThreshold) {
            _burnTax = true;
        }
    }

    /* TRANSFER METHODS */

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        (uint256 _currentTaxRate, bool _burnTax) = _getTaxParams();

        if (_currentTaxRate == 0 || sendersExcludedFromTax[sender] || recipientsExcludedFromTax[recipient]) {
            _transfer(sender, recipient, amount);
        } else {
            _transferWithTax(sender, recipient, amount, _currentTaxRate, _burnTax);
        }
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        (uint256 _currentTaxRate, bool _burnTax) = _getTaxParams();

        if (_currentTaxRate == 0 && !sendersIncludedInTax[msg.sender] && !recipientsIncludedInTax[recipient]) {
            _transfer(msg.sender, recipient, amount);
        } else {
            _transferWithTax(msg.sender, recipient, amount, _currentTaxRate, _burnTax);
        }
    }

    function _transferWithTax(
        address sender,
        address recipient,
        uint256 amount,
        uint256 currentTaxRate,
        bool burnTax
    ) internal returns (bool) {
        uint256 _taxAmount = amount.mul(currentTaxRate).div(10000);
        uint256 _amountAfterTax = amount.sub(_taxAmount);

        if (burnTax) {
            // Burn tax
            tomb.burn(_taxAmount);
            _burn(sender, _taxAmount);
        } else {
            // Transfer tax to tax collector
            _transfer(sender, taxCollectorAddress, _taxAmount);
        }

        // Transfer amount after tax to recipient
        _transfer(sender, recipient, _amountAfterTax);

        return true;
    }

    /* TAX CONTROL */
    function addToSendersExcludedFromTax(address _address) public onlyOperator {
        require(_address != address(0), "Address cannot be 0");
        require(!sendersExcludedFromTax[_address], "Sender already excluded from tax");

        sendersExcludedFromTax[_address] = true;
    }

    function removeFromSendersExcludedFromTax(address _address) public onlyOperator {
        require(_address != address(0), "Address cannot be 0");
        require(sendersExcludedFromTax[_address], "Sender already included in tax");

        sendersExcludedFromTax[_address] = false;
    }

    function addToRecipientsExcludedFromTax(address _address) public onlyOperator {
        require(_address != address(0), "Address cannot be 0");
        require(!recipientsExcludedFromTax[_address], "Recipient already excluded from tax");

        recipientsExcludedFromTax[_address] = true;
    }

    function removeFromRecipientsExcludedFromTax(address _address) public onlyOperator {
        require(_address != address(0), "Address cannot be 0");
        require(recipientsExcludedFromTax[_address], "Recipient already included in tax");

        recipientsExcludedFromTax[_address] = false;
    }

    function addToSendersIncludedInTax(address _address) public onlyOperator {
        require(_address != address(0), "Address cannot be 0");
        require(!sendersIncludedInTax[_address], "Sender already included in tax");

        sendersIncludedInTax[_address] = true;
    }

    function removeFromSendersIncludedInTax(address _address) public onlyOperator {
        require(_address != address(0), "Address cannot be 0");
        require(sendersIncludedInTax[_address], "Sender already excluded from tax");

        sendersIncludedInTax[_address] = false;
    }

    function addToRecipientsIncludedInTax(address _address) public onlyOperator {
        require(_address != address(0), "Address cannot be 0");
        require(!recipientsIncludedInTax[_address], "Recipient already included in tax");

        recipientsIncludedInTax[_address] = true;
    }

    function removeFromRecipientsIncludedInTax(address _address) public onlyOperator {
        require(_address != address(0), "Address cannot be 0");
        require(recipientsIncludedInTax[_address], "Recipient already excluded from tax");

        recipientsIncludedInTax[_address] = false;
    }

    /* SETTERS */

    function setTaxCollectorAddress(address _taxCollectorAddress) public onlyOperator {
        require(_taxCollectorAddress != address(0), "Tax collector address cannot be 0");
        require(_taxCollectorAddress != taxCollectorAddress, "No change of tax collector address");
        address _oldTaxCollectorAddress = taxCollectorAddress;
        taxCollectorAddress = _taxCollectorAddress;
        emit TaxCollectorAddressChanged(msg.sender, _oldTaxCollectorAddress, _taxCollectorAddress);
    }

    function setTaxOffice(address _taxOffice) public onlyOperator {
        require(_taxOffice != address(0), "TaxOffice address cannot be 0");
        address _oldTaxOffice = address(taxOffice);
        taxOffice = ITaxOfficeV2(_taxOffice);
        emit TaxOfficeChanged(msg.sender, _oldTaxOffice, _taxOffice);
    }

    function setOracle(address _oracle) public onlyOperator {
        require(_oracle != address(0), "Oracle address cannot be 0");
        address _oldOracle = address(oracle);
        oracle = IOracle(_oracle);
        emit OracleChanged(msg.sender, _oldOracle, _oracle);
    }

    function setTaxEnabled(bool _taxEnabled) public onlyOperator {
        require(_taxEnabled != taxEnabled, "No change of taxEnabled state");
        taxEnabled = _taxEnabled;
        emit TaxEnabledChanged(msg.sender, _taxEnabled);
    }

    function setStaticTaxRate(uint256 _staticTaxRate) public onlyOperator {
        require(_staticTaxRate < 10000, "Tax equal or bigger to 100%");
        uint256 _oldStaticTaxRate = staticTaxRate;
        staticTaxRate = _staticTaxRate;
        emit StaticTaxRateChanged(msg.sender, _oldStaticTaxRate, staticTaxRate);
    }

    function setAutoCalculateTax(bool _autoCalculateTax) public onlyOperator {
        require(_autoCalculateTax != autoCalculateTax, "No change of autoCalculateTax state");
        autoCalculateTax = _autoCalculateTax;
        emit AutoCalculateTaxChanged(msg.sender, _autoCalculateTax);
    }

    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256 _amount
    ) internal override(ERC20, ERC20Pausable) {
        super._beforeTokenTransfer(_from, _to, _amount);
    }
}
