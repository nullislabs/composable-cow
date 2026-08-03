// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title Mock ERC20 token for testing.
 * @author mfw78 <mfw78@nxm.rs>
 */
contract MockERC20 is ERC20 {
    string private _name;
    string private _symbol;

    /**
     * @dev Initializes a new mock ERC20 token. No tokens are minted, makes use instead
     * of `vm.deal` in tests.
     * @param name_ The name of the token.
     * @param symbol_ The symbol of the token.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }
}

/**
 * @title Tokens - A helper contract for local integration testing.
 * @author mfw78 <mfw78@nxm.rs>
 */
abstract contract Tokens {
    IERC20 public token0;
    IERC20 public token1;
    IERC20 public token2;

    constructor() {
        token0 = IERC20(address(new MockERC20("Token 0", "T0")));
        token1 = IERC20(address(new MockERC20("Token 1", "T1")));
        token2 = IERC20(address(new MockERC20("Token 2", "T2")));
    }
}
