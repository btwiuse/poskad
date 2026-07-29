package main

import (
	"log"

	"github.com/btwiuse/poskad"
)

func main() {
	if err := poskad.NewCommand().Execute(); err != nil {
		log.Fatal(err)
	}
}
