package doctor

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

func (r *runner) localAddress() (string, error) {
	nginx, ok := r.project.Services["nginx"]
	if !ok {
		return "", fmt.Errorf("nginx is not configured")
	}
	for _, p := range nginx.Ports {
		if p.Target != 443 || (p.Protocol != "" && p.Protocol != "tcp") || !validPort(p.Published, false) || p.Published == "" {
			continue
		}
		host := p.HostIP
		switch host {
		case "", "0.0.0.0":
			host = "127.0.0.1"
		case "::":
			host = "::1"
		}
		ip := net.ParseIP(host)
		if ip == nil {
			continue
		}
		local := ip.IsLoopback()
		addresses, _ := net.InterfaceAddrs()
		for _, address := range addresses {
			if addressIP, _, err := net.ParseCIDR(address.String()); err == nil && addressIP.Equal(ip) {
				local = true
			}
		}
		if local {
			return net.JoinHostPort(host, p.Published), nil
		}
	}
	return "", fmt.Errorf("no local HTTPS binding in the active Compose configuration")
}

func (r *runner) http(ctx context.Context) Result {
	if r.running("nginx") == nil {
		return skipped("Local HTTP check requires a running nginx container", true)
	}
	address, err := r.localAddress()
	if err != nil {
		return skipped("No local HTTPS binding could be selected from the active Compose configuration", true)
	}
	bindings, err := r.docker.PublishedPorts(ctx, r.running("nginx").ID)
	if err != nil {
		return failure("The running nginx port bindings could not be inspected", "Check Docker access before probing the site")
	}
	matched := false
	for _, binding := range bindings {
		host := binding.HostIP
		if host == "" || host == "0.0.0.0" {
			host = "127.0.0.1"
		}
		if host == "::" {
			host = "::1"
		}
		if binding.Target == 443 && (binding.Protocol == "" || binding.Protocol == "tcp") && net.JoinHostPort(host, binding.Published) == address {
			matched = true
		}
	}
	if !matched {
		return failure("Running nginx HTTPS binding differs from the effective Compose configuration", "Review HTTPS_PORT and port overrides, then recreate nginx to apply the intended binding")
	}
	transport := &http.Transport{
		// The TLS check below verifies trust, hostname and validity separately,
		// so an expired certificate does not hide the site's HTTP diagnostics.
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true, ServerName: r.inst.SiteHost()}, //nolint:gosec
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, address)
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: r.opts.Timeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	var details, problems, warnings []string
	for _, path := range []string{"/", "/admin/"} {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+r.inst.SiteHost()+path, nil)
		req.Header.Set("User-Agent", "kvsctl-doctor")
		response, err := client.Do(req)
		if err != nil {
			problems = append(problems, path+": local HTTPS request failed")
			continue
		}
		r.response = response
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
		response.Body.Close()
		line := fmt.Sprintf("%s answered HTTP %d", path, response.StatusCode)
		switch {
		case response.StatusCode == 401 || response.StatusCode == 403:
			warnings = append(warnings, line+" (protected; application response could not be checked)")
		case response.StatusCode >= 400:
			problems = append(problems, line)
		case response.StatusCode >= 300:
			location, err := response.Location()
			if err != nil || location.Hostname() != r.inst.SiteHost() {
				warnings = append(warnings, line+" (unexpected or missing redirect target)")
			} else {
				details = append(details, line+" (same-site redirect)")
			}
		default:
			details = append(details, line)
		}
	}
	details = append(details, "Connected directly to "+address+"; redirects were not followed")
	result := good("Local site and admin endpoints responded", details...)
	if len(warnings) > 0 {
		result = warning("Some HTTP responses require interpretation", "Review access restrictions and canonical site URLs", append(warnings, details...)...)
	}
	if len(problems) > 0 {
		result = failure("The local site or admin endpoint did not respond successfully", r.command("logs nginx --tail 100"), append(problems, details...)...)
	}
	result.ready = r.response != nil
	return result
}

func (r *runner) tls(ctx context.Context) Result {
	if r.response == nil || r.response.TLS == nil || len(r.response.TLS.PeerCertificates) == 0 {
		return skipped("No local TLS certificate was received", true)
	}
	certs := r.response.TLS.PeerCertificates
	leaf := certs[0]
	if r.now.Before(leaf.NotBefore) {
		return failure("TLS certificate is not valid yet", "Check the host clock and the certificate's validity dates")
	}
	if !r.now.Before(leaf.NotAfter) {
		return failure("TLS certificate has expired", "Inspect the configured certificate renewal mechanism")
	}
	if leaf.VerifyHostname(r.inst.SiteHost()) != nil {
		return failure("TLS certificate does not cover the configured site hostname", "Inspect the certificate and USE_WWW configuration")
	}
	roots, err := x509.SystemCertPool()
	if err != nil {
		return failure("System certificate trust store is unavailable", "Check the host certificate trust store")
	}
	mode := r.inst.Env["SSL_PROVIDER"]
	if config := r.project.Services["nginx"].Environment["SSL_PROVIDER"]; config != "" {
		mode = config
	}
	if mode == "selfsigned" {
		c := r.running("nginx")
		if c == nil {
			return skipped("Cannot read the configured self-signed certificate without nginx", true)
		}
		pem, err := r.probe.exec(ctx, c.ID, nil, "cat", "/etc/nginx/ssl/"+r.inst.Domain()+"/cert.pem")
		if err != nil {
			return failure("Configured self-signed certificate could not be read from nginx", "Inspect the nginx certificate mount")
		}
		roots = x509.NewCertPool()
		if !roots.AppendCertsFromPEM(pem) {
			return failure("Configured self-signed certificate is unreadable", "Inspect the nginx certificate mount")
		}
	}
	intermediates := x509.NewCertPool()
	for _, cert := range certs[1:] {
		intermediates.AddCert(cert)
	}
	_, err = leaf.Verify(x509.VerifyOptions{DNSName: r.inst.SiteHost(), Roots: roots, Intermediates: intermediates, CurrentTime: r.now})
	if err != nil {
		return failure("TLS certificate is not trusted under the configured TLS mode", "Inspect the certificate chain and SSL_PROVIDER")
	}
	detail := "Expires " + leaf.NotAfter.UTC().Format(time.RFC3339)
	if mode == "selfsigned" {
		detail += "; trusted against the certificate configured inside nginx"
	}
	if leaf.NotAfter.Sub(r.now) < 14*24*time.Hour {
		return warning("TLS certificate expires in less than 14 days", "Inspect certificate renewal before expiration", detail)
	}
	return good("TLS hostname, validity and certificate trust match the configured mode", detail)
}

func (r *runner) dns(ctx context.Context) Result {
	addresses, err := net.DefaultResolver.LookupIPAddr(ctx, r.inst.SiteHost())
	if err != nil || len(addresses) == 0 {
		return failure("The site hostname could not be resolved", "Check DNS and local host overrides")
	}
	var values []string
	for _, address := range addresses {
		values = append(values, address.IP.String())
	}
	sort.Strings(values)
	return good("Site hostname resolves through the system resolver", values...)
}

func (r *runner) publicHTTPS(ctx context.Context) Result {
	host := r.inst.SiteHost()
	if port := r.inst.Env["PROJECT_HTTPS_PORT"]; port != "" && port != "443" {
		host = net.JoinHostPort(host, port)
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+host+"/", nil)
	req.Header.Set("User-Agent", "kvsctl-doctor")
	response, err := r.probe.client.Do(req)
	if err != nil {
		return failure("The site's DNS-resolved HTTPS endpoint could not be verified", "Check routing, public TLS, proxy configuration and local host overrides")
	}
	response.Body.Close()
	if response.StatusCode == 401 || response.StatusCode == 403 {
		return warning("The DNS-resolved HTTPS endpoint is protected", "Review public access restrictions")
	}
	if response.StatusCode >= 400 {
		return failure(fmt.Sprintf("The DNS-resolved HTTPS endpoint answered HTTP %d", response.StatusCode), "Review the public endpoint and origin logs")
	}
	return good(fmt.Sprintf("DNS-resolved HTTPS endpoint answered HTTP %d; redirects were not followed", response.StatusCode))
}

func (r *runner) registries(ctx context.Context) Result {
	hosts := map[string]bool{}
	for _, config := range r.project.Services {
		if config.Image == "" {
			continue
		}
		first, _, slash := strings.Cut(config.Image, "/")
		host := "registry-1.docker.io"
		if slash && (strings.ContainsAny(first, ".:") || first == "localhost") {
			host = first
		}
		hosts[host] = true
	}
	var ordered []string
	for host := range hosts {
		ordered = append(ordered, host)
	}
	sort.Strings(ordered)
	if len(ordered) == 0 {
		return skipped("No image registry is named by the active configuration", false)
	}
	var details, failed []string
	for _, host := range ordered {
		u := &url.URL{Scheme: "https", Host: host, Path: "/v2/"}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
		if err != nil {
			failed = append(failed, "An image registry endpoint could not be parsed")
			continue
		}
		response, err := r.probe.client.Do(req)
		if err != nil {
			failed = append(failed, host+": unreachable or TLS verification failed")
			continue
		}
		response.Body.Close()
		if response.StatusCode != 200 && response.StatusCode != 401 {
			failed = append(failed, fmt.Sprintf("%s: HTTP %d", host, response.StatusCode))
			continue
		}
		details = append(details, fmt.Sprintf("%s: HTTP %d (reachability only; no credentials were sent)", host, response.StatusCode))
	}
	if len(failed) > 0 {
		return failure("Some configured image registries could not be reached", "Check network access and registry availability", append(failed, details...)...)
	}
	return good("Configured image registry endpoints responded", details...)
}
