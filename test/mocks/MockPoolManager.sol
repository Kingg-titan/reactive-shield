// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract MockPoolManager {
    mapping(bytes32 => bytes32) public slots;

    function setExtsload(bytes32 slot, bytes32 value) external {
        slots[slot] = value;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }

    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        for (uint256 i; i < nSlots; i++) values[i] = slots[bytes32(uint256(startSlot) + i)];
    }

    function extsload(bytes32[] calldata requestedSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](requestedSlots.length);
        for (uint256 i; i < requestedSlots.length; i++) values[i] = slots[requestedSlots[i]];
    }

    function asPoolManager() external view returns (IPoolManager) {
        return IPoolManager(address(this));
    }
}

