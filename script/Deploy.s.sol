// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../contracts/PonsRouter.sol";

/// forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
/// Env: FEE_RECIPIENT (required), FEE_BPS (optional, default 50 = 0.5%)
contract Deploy is Script {
    // Robinhood Chain (4663) — double-check on https://robinhoodchain.blockscout.com before deploying
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e; // docs.ponsfamily.com/v2
    address constant PONS_MEME_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044; // docs.ponsfamily.com/v2
    address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951; // substreams.dev (verify!)

    function run() external {
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(50)));
        require(block.chainid == 4663, "not Robinhood Chain");

        vm.startBroadcast();
        PonsRouter router = new PonsRouter(PONS_FACTORY, V4_POOL_MANAGER, PONS_MEME_HOOK, feeRecipient, feeBps);
        vm.stopBroadcast();

        console.log("PonsRouter deployed at", address(router));
    }
}
