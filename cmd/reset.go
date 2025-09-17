package cmd

import (
	"fmt"
	"github.com/spf13/cobra"
	"h-ui/dao"
	"h-ui/util"
	"os"
)

var resetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Reset username and password",
	Long:  "Reset username and password.",
	Run:   runReset,
}

func init() {
	rootCmd.AddCommand(resetCmd)
}

func runReset(cmd *cobra.Command, args []string) {
	username, err := util.RandomString(6)
	if err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}
	password, err := util.RandomString(6)
	if err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}
	if err = dao.InitSqliteDB(); err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}
	if err = dao.UpdateAccount([]int64{1}, map[string]interface{}{
		"username": username,
		"pass":     util.SHA224String(password),
		"con_pass": fmt.Sprintf("%s.%s", username, password)}); err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}
	if err = dao.CloseSqliteDB(); err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}
	fmt.Println(fmt.Sprintf("h-ui Login Username: %s", username))
	fmt.Println(fmt.Sprintf("h-ui Login Password: %s", password))
	fmt.Println(fmt.Sprintf("h-ui Connection Password: %s", fmt.Sprintf("%s.%s", username, password)))
}
