// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

contract UnusedArgProbe {
    function f(uint48) external pure returns (uint256) {
        return 1;
    }

    function g(uint48 x) external pure returns (uint256) {
        return uint256(x);
    }

    struct S {
        uint48 x;
        uint48 y;
    }

    function h(S calldata s) external pure returns (uint256) {
        return uint256(s.x);
    }

    function hashAbiEncode(S calldata s) external pure returns (bytes32) {
        return keccak256(abi.encode(s));
    }

    function hashRawCopy(S calldata s) external pure returns (bytes32 out) {
        assembly ("memory-safe") {
            let mem := mload(0x40)
            calldatacopy(mem, s, 0x40)
            out := keccak256(mem, 0x40)
        }
    }
}

contract UnusedArgDirtyCalldataTest is Test {
    function testDirtyUnusedTopLevelUint48ArgumentReverts() public {
        UnusedArgProbe probe = new UnusedArgProbe();

        bytes memory data = abi.encodeWithSelector(probe.f.selector, uint256(5));
        data[4] = bytes1(0xff);

        (bool ok,) = address(probe).call(data);

        assertFalse(ok, "dirty top-level uint48 argument is decoded even if unused");
    }

    function testDirtyUsedUint48ArgumentReverts() public {
        UnusedArgProbe probe = new UnusedArgProbe();

        bytes memory data = abi.encodeWithSelector(probe.g.selector, uint256(5));
        data[4] = bytes1(0xff);

        (bool ok,) = address(probe).call(data);

        assertFalse(ok, "dirty used uint48 argument should be decoded and rejected");
    }

    function testDirtyUnusedStructFieldSucceeds() public {
        UnusedArgProbe probe = new UnusedArgProbe();

        UnusedArgProbe.S memory s = UnusedArgProbe.S({x: 5, y: 7});
        bytes memory data = abi.encodeWithSelector(probe.h.selector, s);
        // Struct field y is slot 1. It is never read by h(), so dirty high bits
        // are not validated by this compiler/optimizer environment.
        data[4 + 0x20] = bytes1(0xff);

        (bool ok, bytes memory ret) = address(probe).call(data);

        assertTrue(ok, "dirty unused calldata struct field is not decoded");
        assertEq(abi.decode(ret, (uint256)), 5);
    }

    function testDirtyUsedStructFieldReverts() public {
        UnusedArgProbe probe = new UnusedArgProbe();

        UnusedArgProbe.S memory s = UnusedArgProbe.S({x: 5, y: 7});
        bytes memory data = abi.encodeWithSelector(probe.h.selector, s);
        data[4] = bytes1(0xff);

        (bool ok,) = address(probe).call(data);

        assertFalse(ok, "dirty used calldata struct field is decoded and rejected");
    }

    function testDirtyUnusedStructFieldRevertsUnderAbiEncodeHash() public {
        UnusedArgProbe probe = new UnusedArgProbe();

        UnusedArgProbe.S memory s = UnusedArgProbe.S({x: 5, y: 7});
        bytes memory data = abi.encodeWithSelector(probe.hashAbiEncode.selector, s);
        data[4 + 0x20] = bytes1(0xff);

        (bool ok,) = address(probe).call(data);

        assertFalse(ok, "abi.encode(s) forces validation of dirty unused struct field");
    }

    function testDirtyUnusedStructFieldPassesRawCopyHash() public {
        UnusedArgProbe probe = new UnusedArgProbe();

        UnusedArgProbe.S memory s = UnusedArgProbe.S({x: 5, y: 7});
        bytes memory data = abi.encodeWithSelector(probe.hashRawCopy.selector, s);
        data[4 + 0x20] = bytes1(0xff);

        (bool ok,) = address(probe).call(data);

        assertTrue(ok, "raw calldatacopy hash does not force validation of unused struct field");
    }
}
