// Package gcerr defines the sentinel error categories the CLI surfaces to
// users. Exit-code mapping lives in the commands layer; this package just
// classifies the failure.
package gcerr

import (
	"errors"
	"fmt"
)

var (
	ErrAuth     = errors.New("auth")
	ErrNetwork  = errors.New("network")
	ErrConfig   = errors.New("config")
	ErrAPIShape = errors.New("api shape")
	ErrStorage  = errors.New("storage")
)

func Authf(format string, args ...any) error {
	return &gcError{sentinel: ErrAuth, msg: fmt.Sprintf(format, args...)}
}

func Networkf(format string, args ...any) error {
	return &gcError{sentinel: ErrNetwork, msg: fmt.Sprintf(format, args...)}
}

func Configf(format string, args ...any) error {
	return &gcError{sentinel: ErrConfig, msg: fmt.Sprintf(format, args...)}
}

func APIShapef(format string, args ...any) error {
	return &gcError{sentinel: ErrAPIShape, msg: fmt.Sprintf(format, args...)}
}

func Storagef(format string, args ...any) error {
	return &gcError{sentinel: ErrStorage, msg: fmt.Sprintf(format, args...)}
}

type gcError struct {
	sentinel error
	msg      string
}

func (e *gcError) Error() string { return e.msg }
func (e *gcError) Unwrap() error { return e.sentinel }
