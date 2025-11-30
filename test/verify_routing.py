import hashlib
import json
import os
from pathlib import Path

import requests

# Default configuration (can be overridden by generated config)
NUM_NODES = 8
ID_BITS = 66
BYTE_LEN = (ID_BITS + 7) // 8  # 9 bytes


def load_config():
    """
    Optionally override NUM_NODES / ID_BITS from a generated JSON config.

    The localstack deployment script `deploy/localstack/generate-docker-compose.ps1`
    writes `test/verify_routing_config.json` with the current node count so that
    this script stays aligned with the deployed cluster.
    """
    global NUM_NODES, ID_BITS, BYTE_LEN

    # Repo root is one level above this file's directory
    base_dir = Path(__file__).resolve().parents[1]
    cfg_path = base_dir / "test" / "verify_routing_config.json"

    if not cfg_path.exists():
        return

    try:
        with cfg_path.open("r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception as e:
        print(f"Warning: failed to load config from {cfg_path}: {e}")
        return

    if "NUM_NODES" in cfg:
        NUM_NODES = int(cfg["NUM_NODES"])
    if "ID_BITS" in cfg:
        ID_BITS = int(cfg["ID_BITS"])

    BYTE_LEN = (ID_BITS + 7) // 8


def get_id_from_string(s):
    # SHA-1 hash
    h = hashlib.sha1(s.encode('utf-8')).digest()
    
    # Take first BYTE_LEN bytes
    buf = bytearray(h[:BYTE_LEN])
    
    # Mask unused bits in first byte
    extra_bits = BYTE_LEN * 8 - ID_BITS
    if extra_bits > 0:
        mask = 0xFF >> extra_bits
        buf[0] &= mask
        
    return buf.hex()

def get_node_ids():
    # Generate hashed node IDs (same as what the deployment should use)
    ids = []
    for i in range(NUM_NODES):
        node_name = f"koorde-node-{i}"
        hex_id = get_id_from_string(node_name)
        ids.append(hex_id)
    return sorted(ids)

def get_responsible_node(key_hex, node_ids):
    # Find successor: first node_id >= key_hex
    key_int = int(key_hex, 16)
    
    for node_hex in node_ids:
        node_int = int(node_hex, 16)
        if node_int >= key_int:
            return node_hex
            
    # Wrap around to first node
    return node_ids[0]

def test_routing():
    # Load dynamic configuration (if present)
    load_config()

    node_ids = get_node_ids()
    print("Node ID Distribution:")
    for i, node_id in enumerate(node_ids):
        print(f"  Node {i}: 0x{node_id}")
    print(f"\nTotal Nodes: {len(node_ids)}")
    
    urls = [
        "https://httpbin.org/get",
        "https://www.gstatic.com/generate_204",
        "https://www.google.com/robots.txt",
        "https://example.org",             # 200 stable
        "https://neverssl.com",            # simple 200
        "https://httpbin.org/uuid",
        "https://httpbin.org/html",
        "https://www.wikipedia.org/"
    ]
    
    match_count = 0
    total_count = 0
    
    print("\n" + "="*60)
    print("ROUTING VERIFICATION")
    print("="*60)
    
    for url in urls:
        key_hex = get_id_from_string(url)
        expected_node = get_responsible_node(key_hex, node_ids)
        
        print(f"\nURL: {url}")
        print(f"Key ID:        0x{key_hex}")
        print(f"Expected Node: 0x{expected_node}")
        
        try:
            resp = requests.get(f"http://localhost:9000/cache?url={url}")
            if resp.status_code != 200:
                print(f"❌ Request failed with status {resp.status_code}")
                continue
                
            actual_node = resp.headers.get("X-Node-ID", "").replace("0x", "")
            
            # Normalize for comparison
            actual_node = actual_node.zfill(BYTE_LEN * 2)
            
            print(f"Actual Node:   0x{actual_node}")
            
            if actual_node == expected_node:
                print("✅ MATCH")
                match_count += 1
            else:
                print("❌ MISMATCH")
            
            total_count += 1
                
        except Exception as e:
            print(f"Request failed: {e}")

    print("\n" + "="*60)
    print(f"SUMMARY: {match_count}/{total_count} matches")
    print("="*60)

if __name__ == "__main__":
    test_routing()
