// Copyright 2023 The Atlas Operator Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package controller

import (
	"net/url"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"

	dbv1alpha1 "github.com/ariga/atlas-operator/api/v1alpha1"
	"github.com/stretchr/testify/require"
)

func TestAutomaticDevDBSpec_TiDBFailsClosed(t *testing.T) {
	u, err := url.Parse("tidb://root:pass@localhost:4000/myapp")
	require.NoError(t, err)
	_, _, err = AutomaticDevDBSpec(*u, dbv1alpha1.DriverTiDB, true)
	require.Error(t, err)
	require.ErrorContains(t, err, "unsupported driver")
	require.ErrorContains(t, err, "provide the devURL")
}

func TestAutomaticDevDBSpec_MySQLUsesTargetDatabase(t *testing.T) {
	u, err := url.Parse("mysql://root:pass@mysql:3306/myapp?parseTime=true")
	require.NoError(t, err)

	podSpec, devURL, err := AutomaticDevDBSpec(*u, dbv1alpha1.DriverMySQL, true)
	require.NoError(t, err)
	require.Equal(t, "mysql://root:pass@localhost:3306/myapp", devURL)
	assertDatabasePathMatchesEnv(t, devURL, podSpec, "MYSQL_DATABASE")
}

func TestAutomaticDevDBSpec_MariaDBUsesTargetDatabase(t *testing.T) {
	u, err := url.Parse("mariadb://root:pass@mariadb:3306/myapp")
	require.NoError(t, err)

	podSpec, devURL, err := AutomaticDevDBSpec(*u, dbv1alpha1.DriverMariaDB, true)
	require.NoError(t, err)
	require.Equal(t, "mariadb://root:pass@localhost:3306/myapp", devURL)
	assertDatabasePathMatchesEnv(t, devURL, podSpec, "MARIADB_DATABASE")
}

func TestAutomaticDevDBSpec_MySQLNonSchemaBoundUsesDefault(t *testing.T) {
	u, err := url.Parse("mysql://root:pass@mysql:3306")
	require.NoError(t, err)

	podSpec, devURL, err := AutomaticDevDBSpec(*u, dbv1alpha1.DriverMySQL, false)
	require.NoError(t, err)
	require.Equal(t, "mysql://root:pass@localhost:3306", devURL)
	require.Empty(t, containerEnv(podSpec, "MYSQL_DATABASE"))
}

func TestAutomaticDevDBSpec_MySQLRejectsNestedDatabasePath(t *testing.T) {
	u, err := url.Parse("mysql://root:pass@mysql:3306/catalog/myapp")
	require.NoError(t, err)

	_, _, err = AutomaticDevDBSpec(*u, dbv1alpha1.DriverMySQL, true)
	require.EqualError(t, err, `devdb: unsupported MySQL database path "/catalog/myapp"`)
}

func TestAutomaticDevDBSpec_MariaDBRejectsNestedDatabasePath(t *testing.T) {
	u, err := url.Parse("mariadb://root:pass@mariadb:3306/catalog/myapp")
	require.NoError(t, err)

	_, _, err = AutomaticDevDBSpec(*u, dbv1alpha1.DriverMariaDB, true)
	require.EqualError(t, err, `devdb: unsupported MariaDB database path "/catalog/myapp"`)
}

func TestAutomaticDevDBSpec_MySQLUsesEscapedTargetDatabase(t *testing.T) {
	u, err := url.Parse("mysql://root:pass@mysql:3306/my%20app")
	require.NoError(t, err)

	podSpec, devURL, err := AutomaticDevDBSpec(*u, dbv1alpha1.DriverMySQL, true)
	require.NoError(t, err)
	assertDatabasePathMatchesEnv(t, devURL, podSpec, "MYSQL_DATABASE")
}

func TestAutomaticDevDBSpec_DeploymentUsesGeneratedConnectionTemplate(t *testing.T) {
	u, err := url.Parse("mysql://root:pass@mysql:3306/myapp")
	require.NoError(t, err)
	podSpec, devURL, err := AutomaticDevDBSpec(*u, dbv1alpha1.DriverMySQL, true)
	require.NoError(t, err)

	deploy := deploymentDevDB(types.NamespacedName{Name: "mysql", Namespace: "default"}, dbv1alpha1.DriverMySQL, *podSpec, devURL)
	require.Equal(t, devURL, deploy.Spec.Template.Annotations[annoConnTmpl])
	assertDatabasePathMatchesEnv(t, deploy.Spec.Template.Annotations[annoConnTmpl], podSpec, "MYSQL_DATABASE")
}

func containerEnv(podSpec *corev1.PodSpec, name string) string {
	for _, env := range podSpec.Containers[0].Env {
		if env.Name == name {
			return env.Value
		}
	}
	return ""
}

func assertDatabasePathMatchesEnv(t *testing.T, devURL string, podSpec *corev1.PodSpec, envName string) {
	t.Helper()
	u, err := url.Parse(devURL)
	require.NoError(t, err)
	require.Equal(t, strings.TrimPrefix(u.Path, "/"), containerEnv(podSpec, envName))
}
