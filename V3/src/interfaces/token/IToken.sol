// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';

import {ITokenExtensions} from 'V3/interfaces/token/ITokenExtensions.sol';

/// @title IToken
/// @notice Complete interface for the canonical root token.
interface IToken is IERC20, IERC20Metadata, IERC20Permit, ITokenExtensions {}
