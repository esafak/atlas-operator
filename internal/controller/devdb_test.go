// Copyright 2023 The Atlas Operator Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package controller

import (
	"testing"

	dbv1alpha1 "github.com/ariga/atlas-operator/api/v1alpha1"
	"github.com/stretchr/testify/require"
)

func TestAutomaticDevDBSpec_TiDBFailsClosed(t *testing.T) {
	_, _, err := AutomaticDevDBSpec(dbv1alpha1.DriverTiDB, true)
	require.Error(t, err)
	require.ErrorContains(t, err, "unsupported driver")
	require.ErrorContains(t, err, "provide the devURL")
}
