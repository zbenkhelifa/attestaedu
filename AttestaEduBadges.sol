// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  AttestaEduBadges.sol
//  Déploiement sur Polygon (MATIC)
//
//  Déployer avec Hardhat ou Remix :
//    npx hardhat run scripts/deploy.js --network polygon
//
//  Coût déploiement unique : ~0.05$ sur Polygon
//  Coût par badge          : ~0.001$
// ============================================================

contract AttestaEduBadges {

    // ── OWNER (wallet AttestaEdu) ──
    address public owner;

    // ── STRUCTURE D'UN BADGE ──
    struct Badge {
        bytes32 contentHash;   // keccak256 des données du badge
        uint256 issuedAt;      // timestamp Unix
        bool    revoked;       // true si révoqué
        address issuedBy;      // wallet qui a signé (toujours owner au MVP)
    }

    // ── STOCKAGE ──
    // badgeId (ex: "ATT-2026-0012") → Badge
    mapping(string => Badge) private badges;

    // ── EVENTS ──
    event BadgeIssued(
        string  indexed badgeId,
        bytes32         contentHash,
        uint256         timestamp
    );

    event BadgeRevoked(
        string  indexed badgeId,
        uint256         timestamp
    );

    // ── MODIFICATEURS ──
    modifier onlyOwner() {
        require(msg.sender == owner, "AttestaEdu: non autorise");
        _;
    }

    modifier badgeExists(string calldata badgeId) {
        require(badges[badgeId].issuedAt != 0, "AttestaEdu: badge inexistant");
        _;
    }

    modifier badgeNotExists(string calldata badgeId) {
        require(badges[badgeId].issuedAt == 0, "AttestaEdu: badge deja ancre");
        _;
    }

    // ── CONSTRUCTEUR ──
    constructor() {
        owner = msg.sender;
    }

    // ── ANCRER UN BADGE ──
    // Appelé par l'Edge Function Supabase
    function issueBadge(
        string  calldata badgeId,
        bytes32          contentHash
    )
        external
        onlyOwner
        badgeNotExists(badgeId)
        returns (uint256)
    {
        badges[badgeId] = Badge({
            contentHash: contentHash,
            issuedAt:    block.timestamp,
            revoked:     false,
            issuedBy:    msg.sender
        });

        emit BadgeIssued(badgeId, contentHash, block.timestamp);

        return block.timestamp;
    }

    // ── RÉVOQUER UN BADGE ──
    function revokeBadge(string calldata badgeId)
        external
        onlyOwner
        badgeExists(badgeId)
    {
        require(!badges[badgeId].revoked, "AttestaEdu: deja revoque");
        badges[badgeId].revoked = true;
        emit BadgeRevoked(badgeId, block.timestamp);
    }

    // ── VÉRIFIER UN BADGE (lecture publique, gratuite) ──
    function getBadge(string calldata badgeId)
        external
        view
        returns (
            bytes32 contentHash,
            uint256 issuedAt,
            bool    revoked
        )
    {
        Badge memory b = badges[badgeId];
        return (b.contentHash, b.issuedAt, b.revoked);
    }

    // ── VÉRIFIER L'INTÉGRITÉ ──
    // Recalcule le hash et compare — prouve que les données n'ont pas changé
    function verifyIntegrity(
        string calldata badgeId,
        string calldata badgeDataJson
    )
        external
        view
        badgeExists(badgeId)
        returns (bool)
    {
        bytes32 computedHash = keccak256(abi.encodePacked(badgeDataJson));
        return computedHash == badges[badgeId].contentHash;
    }

    // ── TRANSFÉRER OWNERSHIP (si AttestaEdu change de wallet) ──
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "AttestaEdu: adresse nulle");
        owner = newOwner;
    }
}
