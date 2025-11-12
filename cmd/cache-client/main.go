package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/peterh/liner"
)

func main() {
	// CLI flags
	addr := flag.String("addr", "http://localhost:8080", "Address of the Koorde cache server")
	timeout := flag.Duration("timeout", 30*time.Second, "Request timeout (e.g., 30s)")
	flag.Parse()

	fmt.Printf("Koorde Web Cache interactive client. Connected to %s\n", *addr)
	fmt.Println("Available commands: cache/metrics/health/hotspots/debug/clear/help/exit")
	fmt.Println("")

	// Setup liner shell
	line := liner.NewLiner()
	defer line.Close()
	line.SetCtrlCAborts(true)

	client := &http.Client{
		Timeout: *timeout,
	}
	currentAddr := *addr

	for {
		input, err := line.Prompt(fmt.Sprintf("cache[%s]> ", currentAddr))
		if err != nil {
			if errors.Is(err, liner.ErrPromptAborted) {
				fmt.Println("Aborted")
				continue
			}
			break
		}
		line.AppendHistory(input)

		args := strings.Fields(strings.TrimSpace(input))
		if len(args) == 0 {
			continue
		}
		cmd := args[0]

		switch cmd {

		case "cache", "get":
			if len(args) < 2 {
				fmt.Println("Usage: cache <url>")
				fmt.Println("Example: cache https://www.example.com")
				continue
			}
			url := args[1]
			
			start := time.Now()
			resp, err := client.Get(fmt.Sprintf("%s/cache?url=%s", currentAddr, url))
			latency := time.Since(start)
			
			if err != nil {
				fmt.Printf("Cache request failed: %v | latency=%s\n", err, latency)
				continue
			}
			defer resp.Body.Close()

			// Read response
			body, err := io.ReadAll(resp.Body)
			if err != nil {
				fmt.Printf("Failed to read response: %v\n", err)
				continue
			}

			// Show headers
			cacheStatus := resp.Header.Get("X-Cache")
			nodeID := resp.Header.Get("X-Node-ID")
			responsibleNode := resp.Header.Get("X-Responsible-Node")
			
			fmt.Printf("Status: %d | Cache: %s | Latency: %s\n", 
				resp.StatusCode, cacheStatus, latency)
			fmt.Printf("Node: %s", nodeID)
			if responsibleNode != "" {
				fmt.Printf(" | Responsible: %s", responsibleNode)
			}
			fmt.Println()
			
			// Show content preview
			contentPreview := string(body)
			if len(contentPreview) > 200 {
				contentPreview = contentPreview[:200] + "..."
			}
			fmt.Printf("Content (%d bytes):\n%s\n", len(body), contentPreview)

		case "metrics", "stats":
			resp, err := client.Get(fmt.Sprintf("%s/metrics", currentAddr))
			if err != nil {
				fmt.Printf("Metrics request failed: %v\n", err)
				continue
			}
			defer resp.Body.Close()

			var metrics map[string]interface{}
			if err := json.NewDecoder(resp.Body).Decode(&metrics); err != nil {
				fmt.Printf("Failed to parse metrics: %v\n", err)
				continue
			}

			// Pretty print
			prettyJSON, _ := json.MarshalIndent(metrics, "", "  ")
			fmt.Println(string(prettyJSON))

		case "health":
			resp, err := client.Get(fmt.Sprintf("%s/health", currentAddr))
			if err != nil {
				fmt.Printf("Health check failed: %v\n", err)
				continue
			}
			defer resp.Body.Close()

			var health map[string]interface{}
			if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
				fmt.Printf("Failed to parse health response: %v\n", err)
				continue
			}

			healthy := health["healthy"].(bool)
			status := health["status"].(string)
			nodeID := health["node_id"].(string)

			if healthy {
				fmt.Printf("✓ Healthy: %s | Node: %s\n", status, nodeID)
			} else {
				fmt.Printf("✗ Unhealthy: %s | Node: %s\n", status, nodeID)
			}

		case "hotspots", "hot":
			resp, err := client.Get(fmt.Sprintf("%s/metrics", currentAddr))
			if err != nil {
				fmt.Printf("Metrics request failed: %v\n", err)
				continue
			}
			defer resp.Body.Close()

			var metrics map[string]interface{}
			if err := json.NewDecoder(resp.Body).Decode(&metrics); err != nil {
				fmt.Printf("Failed to parse metrics: %v\n", err)
				continue
			}

			hotspots := metrics["hotspots"].(map[string]interface{})
			count := int(hotspots["count"].(float64))
			urls := hotspots["urls"].([]interface{})

			fmt.Printf("Hotspots detected: %d\n", count)
			if count > 0 {
				fmt.Println("Hot URLs:")
				for i, url := range urls {
					fmt.Printf("  [%d] %s\n", i+1, url)
				}
			} else {
				fmt.Println("  (none)")
			}

		case "debug":
			resp, err := client.Get(fmt.Sprintf("%s/debug", currentAddr))
			if err != nil {
				fmt.Printf("Debug request failed: %v\n", err)
				continue
			}
			defer resp.Body.Close()

			var debug map[string]interface{}
			if err := json.NewDecoder(resp.Body).Decode(&debug); err != nil {
				fmt.Printf("Failed to parse debug response: %v\n", err)
				continue
			}

			prettyJSON, _ := json.MarshalIndent(debug, "", "  ")
			fmt.Println(string(prettyJSON))

		case "use", "connect":
			if len(args) < 2 {
				fmt.Println("Usage: use <addr>")
				fmt.Println("Example: use http://localhost:8081")
				continue
			}
			newAddr := args[1]
			
			// Ensure http:// prefix
			if !strings.HasPrefix(newAddr, "http://") && !strings.HasPrefix(newAddr, "https://") {
				newAddr = "http://" + newAddr
			}
			
			// Test connection
			resp, err := client.Get(fmt.Sprintf("%s/health", newAddr))
			if err != nil {
				fmt.Printf("Failed to connect to %s: %v\n", newAddr, err)
				continue
			}
			resp.Body.Close()
			
			currentAddr = newAddr
			fmt.Printf("Switched to %s\n", currentAddr)

		case "help", "?":
			fmt.Println("Available commands:")
			fmt.Println("  cache <url>       - Cache a URL and retrieve content")
			fmt.Println("  metrics           - Show cache statistics")
			fmt.Println("  health            - Check node health")
			fmt.Println("  hotspots          - Show detected hot URLs")
			fmt.Println("  debug             - Show routing table info")
			fmt.Println("  use <addr>        - Switch to different node")
			fmt.Println("  help              - Show this help")
			fmt.Println("  exit              - Exit client")
			fmt.Println("")
			fmt.Println("Examples:")
			fmt.Println("  cache https://www.example.com")
			fmt.Println("  cache https://httpbin.org/json")
			fmt.Println("  metrics")
			fmt.Println("  use http://localhost:8081")

		case "exit", "quit", "q":
			fmt.Println("Bye!")
			return

		default:
			fmt.Printf("Unknown command: %s\n", cmd)
			fmt.Println("Type 'help' for available commands")
		}
	}
}

