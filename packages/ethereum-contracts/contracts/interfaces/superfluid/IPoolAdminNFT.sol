// SPDX-License-Identifier: AGPLv3
pragma solidity >=0.8.4;

import { IPoolNFTBase } from "./IPoolNFTBase.sol";

interface IPoolAdminNFT is IPoolNFTBase {
    // PoolAdminNFTData struct storage packing:
    // b = bits
    // WORD 1: | pool   | FREE
    //         | 160b   | 96b
    // WORD 2: | member | FREE
    //         | 160b   | 96b
    // WORD 3: | units  | FREE
    //         | 128b   | 128b
    struct PoolAdminNFTData {
        address pool;
        address admin;
    }

    error POOL_ADMIN_NFT_TRANSFER_NOT_ALLOWED();

    /// Write Functions ///
    function mint(address pool) external;

    /// View Functions ///

    function getTokenId(address pool, address admin) external view returns (uint256 tokenId);
}