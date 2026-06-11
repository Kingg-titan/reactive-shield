// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ILComputer} from "../src/ILComputer.sol";

contract ILComputerTest is Test {
    uint160 internal constant Q96 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant SQRT_2_X96 = 112_045_541_949_572_279_837_463_876_454;
    uint160 internal constant INV_SQRT_2_X96 = 56_022_770_974_786_139_918_731_938_227;

    function testKnownValues() external pure {
        assertEq(ILComputer.computeILBps(Q96, Q96), 0);
        assertApproxEqAbs(ILComputer.computeILBps(Q96, SQRT_2_X96), 572, 1);
        assertApproxEqAbs(ILComputer.computeILBps(Q96, INV_SQRT_2_X96), 572, 1);
        assertApproxEqAbs(ILComputer.computeILBps(Q96, Q96 * 2), 2_000, 1);
    }

    function testFuzzILBounded(uint160 entry, uint160 current) external pure {
        entry = uint160(bound(entry, Q96 / 1_000_000, Q96 * 1_000_000));
        current = uint160(bound(current, Q96 / 1_000_000, Q96 * 1_000_000));
        assertLe(ILComputer.computeILBps(entry, current), 10_000);
    }
}
