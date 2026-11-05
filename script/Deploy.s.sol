// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../contracts/PonsRouter.sol";

interface IPeripheryState {
    function WETH9() external view returns (address);
    function factory() external view returns (address);
}

/// Deploy PonsRouter to Robinhood Chain (chain id 4663).
///
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --private-key $PK --broadcast
///
/// Env: FEE_RECIPIENT (required): wallet that receives the frontend fees
///      FEE_BPS       (optional): frontend fee in basis points, default 50 = 0.5%, max 100 = 1%
contract Deploy is Script {
    // Pons v2 (docs.ponsfamily.com/v2)
    address constant PONS_V2_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant PONS_MEME_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    // Uniswap v4 PoolManager (substreams.dev): checked for code below
    address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    // Uniswap V3 on Robinhood Chain (docs.ponsfamily.com and Uniswap's deployment list agree)
    address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    function run() external {
        require(block.chainid == 4663, "not Robinhood Chain (4663)");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(50));
        require(feeRecipient != address(0), "FEE_RECIPIENT is empty");
        require(feeBps <= 100, "FEE_BPS above 1%");

        // ---- sanity checks against the live chain: abort instead of deploying with a wrong address ----
        require(PONS_V2_FACTORY.code.length > 0, "Pons v2 factory has no code");
        require(PONS_MEME_HOOK.code.length > 0, "Pons meme hook has no code");
        require(V4_POOL_MANAGER.code.length > 0, "v4 PoolManager has no code");
        require(SWAP_ROUTER_02.code.length > 0, "SwapRouter02 has no code");
        require(IPeripheryState(SWAP_ROUTER_02).WETH9() == WETH, "SwapRouter02 uses a different WETH");
        require(IPeripheryState(SWAP_ROUTER_02).factory() == V3_FACTORY, "SwapRouter02 uses a different V3 factory");
        console.log("Address checks passed.");

        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 fee16 = uint16(feeBps); // safe: feeBps <= 100 is required above
        vm.startBroadcast();
        PonsRouter router = new PonsRouter(
            PONS_V2_FACTORY, V4_POOL_MANAGER, PONS_MEME_HOOK, SWAP_ROUTER_02, V3_FACTORY, WETH, feeRecipient, fee16
        );
        vm.stopBroadcast();

        console.log("PonsRouter deployed at", address(router));
        console.log("Fee recipient:", feeRecipient);
        console.log("Fee (bps):", feeBps);
        console.log("Next: set ROUTER_ADDRESS on Railway to the address above.");
    }
}
