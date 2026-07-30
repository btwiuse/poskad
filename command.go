package poskad

import (
	"github.com/spf13/cobra"
)

// NewCommand creates the poskad command-line interface. Environment variables
// provide flag defaults; supplying a flag overrides its corresponding value.
func NewCommand() *cobra.Command {
	config := ConfigFromEnv()

	cmd := &cobra.Command{
		Use:           "poskad",
		Short:         "Generate and browse X post cards",
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(_ *cobra.Command, _ []string) error {
			return RunWithConfig(config)
		},
	}

	flags := cmd.Flags()
	flags.StringVarP(&config.Port, "port", "p", config.Port, "HTTP listen port (env: PORT)")
	flags.StringVarP(&config.OutputDir, "output-dir", "o", config.OutputDir, "Directory for generated cards (env: OUTPUT_DIR)")
	flags.StringVar(&config.PoskadScript, "poskad-script", config.PoskadScript, "Path to poskad.sh (env: POSKAD_SCRIPT)")
	flags.StringVarP(&config.WorkDir, "work-dir", "w", config.WorkDir, "Working directory for poskad.sh (env: WORK_DIR)")

	return cmd
}
