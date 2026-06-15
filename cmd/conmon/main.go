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
	Short: "conMon ? ???????????",
	Long: `conMon (Connection Monitor) ???????????????????
??????????????????? SLA ???`,
}

func init() {
	rootCmd.AddCommand(serverCmd)
	rootCmd.AddCommand(probeCmd)
	rootCmd.AddCommand(statusCmd)
	rootCmd.AddCommand(versionCmd)
}

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "??????",
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
	Short: "?????????????",
	RunE: func(cmd *cobra.Command, args []string) error {
		serverAddr, _ := cmd.Flags().GetString("server")
		return runStatus(serverAddr)
	},
}

func init() {
	statusCmd.Flags().StringP("server", "s", "http://localhost:11080", "conMon ?????")
	statusCmd.Flags().StringP("filter", "f", "", "????? (DOWN/UP/DEGRADED/...)")
}

func runStatus(serverAddr string) error {
	fmt.Printf("??????: %s\n", serverAddr)
	fmt.Println("????????? (??????? API /api/v1/status)")
	return nil
}
