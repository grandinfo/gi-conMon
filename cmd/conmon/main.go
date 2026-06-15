// Command conmon is the unified CLI for conMon.
package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
	"github.com/grandinfo/gi-conMon/internal/version"
)

func main() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

var rootCmd = &cobra.Command{
	Use:   "conmon",
	Short: "conMon — 企业级网络连接监控工具",
	Long: `conMon (Connection Monitor) 是一款面向生产环境的网络连接监控工具，
支持多协议探测、智能告警、可视化大屏与 SLA 报表。`,
}

func init() {
	rootCmd.AddCommand(serverCmd)
	rootCmd.AddCommand(probeCmd)
	rootCmd.AddCommand(statusCmd)
	rootCmd.AddCommand(versionCmd)
}

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "显示版本信息",
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Printf("conMon %s (commit: %s, built: %s, go: %s)\n",
			version.Version,
			version.GitCommit,
			version.BuildDate,
			version.GoVersion,
		)
	},
}

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "查看所有监控目标的当前状态",
	RunE: func(cmd *cobra.Command, args []string) error {
		serverAddr, _ := cmd.Flags().GetString("server")
		return runStatus(serverAddr)
	},
}

func init() {
	statusCmd.Flags().StringP("server", "s", "http://localhost:8080", "conMon 服务器地址")
	statusCmd.Flags().StringP("filter", "f", "", "按状态过滤 (DOWN/UP/DEGRADED/...)")
}

func runStatus(serverAddr string) error {
	fmt.Printf("连接到服务器: %s\n", serverAddr)
	fmt.Println("状态查询功能已启用 (完整实现请参阅 API /api/v1/status)")
	return nil
}
