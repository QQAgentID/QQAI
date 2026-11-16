// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Non-custodial market for QQAI NFTs only. A listing never takes the NFT: the NFT stays in
///         the seller's wallet until buy() moves it straight seller -> buyer in the same transaction that
///         splits the exact BNB price between the seller and TREASURY (market fee). Listing therefore needs
///         the standard ERC-721 approval of this contract (single-token approve or setApprovalForAll).
///         No owner, no pause, no upgrade, no admin withdrawal; the fee rate and TREASURY are fixed at deploy.
///
/// @dev FEE_BPS is set at deployment to 250 (2.5%), as decided by the project owner; it cannot be
///      changed afterwards.
contract QQAIMarket is ReentrancyGuard {
    uint256 private constant BPS = 10_000;

    IERC721 public immutable NFT;
    address public immutable TREASURY;
    uint256 public immutable FEE_BPS;

    struct Listing {
        address seller;
        uint256 price;
    }

    mapping(uint256 => Listing) public listings;

    event Listed(address indexed seller, uint256 indexed tokenId, uint256 price);
    event Bought(address indexed buyer, address indexed seller, uint256 indexed tokenId, uint256 price, uint256 fee);
    event Cancelled(address indexed seller, uint256 indexed tokenId);

    constructor(address nft_, address treasury_, uint256 feeBps_) {
        require(nft_ != address(0) && treasury_ != address(0), "address");
        require(feeBps_ <= 1_000, "fee");
        NFT = IERC721(nft_);
        TREASURY = treasury_;
        FEE_BPS = feeBps_;
    }

    /// @dev BNB only ever flows through buy(); anything sent directly would have no way out.
    receive() external payable {
        revert("no direct BNB");
    }

    function owner() external pure returns (address) {
        return address(0);
    }

    /// @notice List your NFT at `price` BNB (wei). The NFT stays in your wallet; this contract must be
    ///         approved for it (approve or setApprovalForAll) so buy() can settle the sale.
    function list(uint256 tokenId, uint256 price) external {
        require(price != 0, "price");
        require(NFT.ownerOf(tokenId) == msg.sender, "not NFT owner");
        require(
            NFT.getApproved(tokenId) == address(this) || NFT.isApprovedForAll(msg.sender, address(this)), "market not approved"
        );
        listings[tokenId] = Listing({seller: msg.sender, price: price});
        emit Listed(msg.sender, tokenId, price);
    }

    /// @notice Buy a listed NFT paying its exact BNB price: the fee goes to TREASURY, the rest to the seller,
    ///         and the NFT moves seller -> buyer atomically.
    function buy(uint256 tokenId) external payable nonReentrant {
        Listing memory listing = listings[tokenId];
        require(listing.price != 0, "not listed");
        require(msg.value == listing.price, "value");
        // Explicit stale-listing guard (audit fix, 15 Nov 2026): if the
        // seller transferred or burned the NFT after listing, fail here
        // with a clear reason instead of inside transferFrom.
        require(NFT.ownerOf(tokenId) == listing.seller, "seller not owner");
        delete listings[tokenId];
        uint256 fee = listing.price * FEE_BPS / BPS;
        uint256 sellerAmount = listing.price - fee;
        NFT.transferFrom(listing.seller, msg.sender, tokenId);
        (bool sentSeller,) = listing.seller.call{value: sellerAmount}("");
        require(sentSeller, "seller send");
        if (fee != 0) {
            (bool sentFee,) = TREASURY.call{value: fee}("");
            require(sentFee, "fee send");
        }
        emit Bought(msg.sender, listing.seller, tokenId, listing.price, fee);
    }

    /// @notice Only the seller can cancel their listing. The NFT never moved, so nothing else is needed.
    function cancelListing(uint256 tokenId) external {
        require(listings[tokenId].seller == msg.sender, "not seller");
        delete listings[tokenId];
        emit Cancelled(msg.sender, tokenId);
    }
}
