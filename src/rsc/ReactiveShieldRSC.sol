// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

contract ReactiveShieldRSC is IReactive, AbstractReactive {
    uint64 public constant CALLBACK_GAS_LIMIT = 1_500_000;

    uint256 public immutable DESTINATION_CHAIN_ID;
    address public immutable HOOK_ADDRESS;
    uint256 public immutable ORIGIN_CHAIN_ID;
    uint256 public immutable PRICE_DEVIATION_TOPIC0;
    address public immutable CALLBACK_SENDER;

    bool public subscriptionConfigured;
    mapping(bytes32 => bool) public settlementQueued;

    event SubscriptionConfigured(uint256 indexed chainId, address indexed hook, uint256 indexed topic0);
    event SettlementQueued(bytes32 indexed poolId, uint160 sqrtPriceX96, uint256 observedAt);
    event PriceDeviationIgnored(bytes32 indexed poolId, string reason);

    constructor(uint256 originChainId, uint256 destinationChainId, address hookAddress) {
        ORIGIN_CHAIN_ID = originChainId;
        DESTINATION_CHAIN_ID = destinationChainId;
        HOOK_ADDRESS = hookAddress;
        PRICE_DEVIATION_TOPIC0 = uint256(keccak256("PriceDeviation(bytes32,uint160,uint256,uint256)"));
        CALLBACK_SENDER = msg.sender;

        bytes memory payload = abi.encodeWithSignature(
            "subscribe(uint256,address,uint256,uint256,uint256,uint256)",
            originChainId,
            hookAddress,
            PRICE_DEVIATION_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        (bool ok,) = address(service).call(payload);
        subscriptionConfigured = ok;
        if (ok) emit SubscriptionConfigured(originChainId, hookAddress, PRICE_DEVIATION_TOPIC0);
    }

    function configureSubscription() external rnOnly {
        service.subscribe(
            ORIGIN_CHAIN_ID,
            HOOK_ADDRESS,
            PRICE_DEVIATION_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        subscriptionConfigured = true;
        emit SubscriptionConfigured(ORIGIN_CHAIN_ID, HOOK_ADDRESS, PRICE_DEVIATION_TOPIC0);
    }

    function react(LogRecord calldata log) external vmOnly override {
        if (log.chain_id != ORIGIN_CHAIN_ID || log._contract != HOOK_ADDRESS || log.topic_0 != PRICE_DEVIATION_TOPIC0) {
            return;
        }

        bytes32 poolId = bytes32(log.topic_1);
        (uint160 sqrtPriceX96, uint256 observedAt, uint256 insuredLPCount) =
            abi.decode(log.data, (uint160, uint256, uint256));

        if (insuredLPCount == 0) {
            emit PriceDeviationIgnored(poolId, "NO_INSURED_LPS");
            return;
        }

        bytes32 queueKey = keccak256(abi.encode(poolId, sqrtPriceX96, observedAt));
        if (settlementQueued[queueKey]) {
            emit PriceDeviationIgnored(poolId, "ALREADY_QUEUED");
            return;
        }
        settlementQueued[queueKey] = true;

        bytes memory payload = abi.encodeWithSignature(
            "settlePoolFromReactive(address,bytes32,uint160)",
            CALLBACK_SENDER,
            poolId,
            sqrtPriceX96
        );
        emit SettlementQueued(poolId, sqrtPriceX96, observedAt);
        emit Callback(DESTINATION_CHAIN_ID, HOOK_ADDRESS, CALLBACK_GAS_LIMIT, payload);
    }
}

