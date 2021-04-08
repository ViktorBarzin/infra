package main

import (
	"fmt"
	"io/ioutil"
	"os"
	"strings"

	"github.com/badoux/checkmail"
	"github.com/brianvoe/gofakeit/v6"
	"github.com/golang/glog"
	"github.com/pkg/errors"
)

const (
	addEmailAliasUseCase           = "add-email-alias"
	emailAliasFlagName             = "forward-to"
	fromEmailDomainFlagName        = "from-domain"
	emailAliasesConfigFileRelative = "/modules/kubernetes/mailserver/extra/aliases.txt"
)

func addEmailAlias(gitFs *GitFS, to, fromDomain string) (string, error) {
	if err := checkmail.ValidateFormat(to); err != nil {
		return "", errors.Wrapf(err, fmt.Sprintf("failed to create new email aliases because invalid input format: %s", to))
	}
	if err := checkmail.ValidateHost(to); err != nil {
		return "", errors.Wrapf(err, fmt.Sprintf("failed to create new email aliases because domain for %s does not exist", to))
	}
	aliasEmail := generateRandomEmail(fromDomain)
	glog.Infof("Adding %s -> %s alias to %s", aliasEmail, to, emailAliasesConfigFileRelative)
	contents := fmt.Sprintf("%s %s", aliasEmail, to)

	// Read existing contents
	fRead, err := (*gitFs.fs).OpenFile(emailAliasesConfigFileRelative, os.O_RDONLY, 0644)
	if err != nil {
		return "", errors.Wrapf(err, "failed to open file where email aliases are recorded")
	}
	fileContentsBytes, err := ioutil.ReadAll(fRead)
	if err != nil {
		return "", errors.Wrapf(err, "failed to read existing aliases file")
	}
	defer fRead.Close()
	newContents := getAddedAliasContents(string(fileContentsBytes), aliasEmail, to)

	// Write new contents
	fWrite, err := (*gitFs.fs).OpenFile(emailAliasesConfigFileRelative, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0644)
	if err != nil {
		return "", errors.Wrapf(err, "failed to open file where new email alias will be added")
	}
	defer fWrite.Close()

	glog.Infof("writing new contents to file: %s", newContents)
	fRead.Write([]byte(newContents))

	if _, err = fWrite.Write([]byte(contents)); err != nil {
		return "", errors.Wrapf(err, "failed to write config to file")
	}
	return aliasEmail, nil
}

func generateRandomEmail(fromDomain string) string {
	return fmt.Sprintf("%s-%s-generated%s", strings.ToLower(gofakeit.Adverb()), strings.ToLower(gofakeit.FirstName()), fromDomain)
}

func getPostFixAlias(from, to string) string {
	return fmt.Sprintf("%s %s", from, to)
}

func getAddedAliasContents(currentContents, from, to string) string {
	glog.Infof("Existingcontent: %s", currentContents)
	lines := strings.Split(currentContents, "\n")
	newLines := []string{}
	// If `to` already has an alias, overwrite it
	for _, l := range lines {
		if !strings.HasSuffix(l, to) {
			newLines = append(newLines, l)
		}
	}
	newLines = append(newLines, getPostFixAlias(from, to))
	return strings.Join(newLines, "\n") + "\n"
}
