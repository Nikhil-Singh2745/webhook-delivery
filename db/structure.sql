SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: reject_event_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_event_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'Events are immutable'
    USING ERRCODE = '23514', CONSTRAINT = 'events_are_immutable';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: api_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_credentials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    token_digest character varying(64) NOT NULL,
    revoked_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT api_credentials_digest_format CHECK (((token_digest)::text ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    event_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    state character varying DEFAULT 'pending'::character varying NOT NULL,
    run_number integer DEFAULT 1 NOT NULL,
    attempts_in_run integer DEFAULT 0 NOT NULL,
    total_attempts bigint DEFAULT 0 NOT NULL,
    next_attempt_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP,
    last_error_code character varying(64),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT deliveries_counters CHECK (((run_number >= 1) AND ((attempts_in_run >= 0) AND (attempts_in_run <= 8)) AND (total_attempts >= attempts_in_run))),
    CONSTRAINT deliveries_error_code CHECK (((last_error_code IS NULL) OR ((last_error_code)::text ~ '^[a-z][a-z0-9_]{0,63}$'::text))),
    CONSTRAINT deliveries_schedule CHECK ((((state)::text = ANY ((ARRAY['pending'::character varying, 'retry_wait'::character varying])::text[])) = (next_attempt_at IS NOT NULL))),
    CONSTRAINT deliveries_state CHECK (((state)::text = ANY ((ARRAY['pending'::character varying, 'delivering'::character varying, 'retry_wait'::character varying, 'succeeded'::character varying, 'failed'::character varying, 'canceled'::character varying])::text[]))),
    CONSTRAINT deliveries_state_attempts CHECK (((((state)::text = 'pending'::text) AND (attempts_in_run = 0)) OR (((state)::text = 'retry_wait'::text) AND ((attempts_in_run >= 1) AND (attempts_in_run <= 7))) OR (((state)::text = ANY ((ARRAY['delivering'::character varying, 'succeeded'::character varying, 'failed'::character varying])::text[])) AND ((attempts_in_run >= 1) AND (attempts_in_run <= 8))) OR ((state)::text = 'canceled'::text)))
);


--
-- Name: delivery_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    delivery_id uuid NOT NULL,
    run_number integer NOT NULL,
    attempt_number integer NOT NULL,
    outcome character varying DEFAULT 'in_progress'::character varying NOT NULL,
    started_at timestamp(6) without time zone NOT NULL,
    finished_at timestamp(6) without time zone,
    http_status integer,
    error_code character varying(64),
    CONSTRAINT attempts_completion CHECK (((((outcome)::text = 'in_progress'::text) AND (finished_at IS NULL) AND (http_status IS NULL) AND (error_code IS NULL)) OR (((outcome)::text <> 'in_progress'::text) AND (finished_at IS NOT NULL) AND (finished_at >= started_at)))),
    CONSTRAINT attempts_error_code CHECK (((error_code IS NULL) OR ((error_code)::text ~ '^[a-z][a-z0-9_]{0,63}$'::text))),
    CONSTRAINT attempts_http_status CHECK (((http_status IS NULL) OR ((http_status >= 100) AND (http_status <= 599)))),
    CONSTRAINT attempts_numbering CHECK (((run_number >= 1) AND ((attempt_number >= 1) AND (attempt_number <= 8)))),
    CONSTRAINT attempts_outcome CHECK (((outcome)::text = ANY ((ARRAY['in_progress'::character varying, 'succeeded'::character varying, 'transient_failure'::character varying, 'permanent_failure'::character varying, 'unknown'::character varying, 'canceled'::character varying])::text[]))),
    CONSTRAINT attempts_success_status CHECK ((((outcome)::text <> 'succeeded'::text) OR ((http_status IS NOT NULL) AND ((http_status >= 200) AND (http_status <= 299)))))
);


--
-- Name: endpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.endpoints (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    url text NOT NULL,
    signing_secret_ciphertext text NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    disabled_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT endpoints_required_content CHECK (((btrim(url) <> ''::text) AND (btrim(signing_secret_ciphertext) <> ''::text))),
    CONSTRAINT endpoints_status CHECK (((((status)::text = 'active'::text) AND (disabled_at IS NULL)) OR (((status)::text = 'disabled'::text) AND (disabled_at IS NOT NULL))))
);


--
-- Name: events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    idempotency_key character varying(128) NOT NULL,
    request_fingerprint character varying(64) NOT NULL,
    event_type character varying(100) NOT NULL,
    data jsonb NOT NULL,
    outbound_body text NOT NULL,
    delivery_count integer NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT events_body_size CHECK (((octet_length(outbound_body) >= 1) AND (octet_length(outbound_body) <= 131072))),
    CONSTRAINT events_data_object CHECK ((jsonb_typeof(data) = 'object'::text)),
    CONSTRAINT events_delivery_count CHECK ((delivery_count >= 0)),
    CONSTRAINT events_fingerprint_format CHECK (((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT events_key_format CHECK (((idempotency_key)::text ~ '^[A-Za-z0-9._:-]{1,128}$'::text)),
    CONSTRAINT events_type_format CHECK (((event_type)::text ~ '^[a-z][a-z0-9_]*([.][a-z][a-z0-9_]*)*$'::text))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT tenants_name_present CHECK ((btrim((name)::text) <> ''::text))
);


--
-- Name: api_credentials api_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_credentials
    ADD CONSTRAINT api_credentials_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: deliveries deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_pkey PRIMARY KEY (id);


--
-- Name: delivery_attempts delivery_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_attempts
    ADD CONSTRAINT delivery_attempts_pkey PRIMARY KEY (id);


--
-- Name: endpoints endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.endpoints
    ADD CONSTRAINT endpoints_pkey PRIMARY KEY (id);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: attempts_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX attempts_identity ON public.delivery_attempts USING btree (delivery_id, run_number, attempt_number);


--
-- Name: attempts_one_in_progress; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX attempts_one_in_progress ON public.delivery_attempts USING btree (delivery_id) WHERE ((outcome)::text = 'in_progress'::text);


--
-- Name: deliveries_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX deliveries_due ON public.deliveries USING btree (next_attempt_at, id) WHERE ((state)::text = ANY ((ARRAY['pending'::character varying, 'retry_wait'::character varying])::text[]));


--
-- Name: index_api_credentials_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_credentials_on_tenant_id ON public.api_credentials USING btree (tenant_id);


--
-- Name: index_api_credentials_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_api_credentials_on_token_digest ON public.api_credentials USING btree (token_digest);


--
-- Name: index_deliveries_on_endpoint_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_deliveries_on_endpoint_id ON public.deliveries USING btree (endpoint_id);


--
-- Name: index_deliveries_on_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_deliveries_on_event_id ON public.deliveries USING btree (event_id);


--
-- Name: index_deliveries_on_event_id_and_endpoint_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_deliveries_on_event_id_and_endpoint_id ON public.deliveries USING btree (event_id, endpoint_id);


--
-- Name: index_deliveries_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_deliveries_on_tenant_id ON public.deliveries USING btree (tenant_id);


--
-- Name: index_deliveries_on_tenant_id_and_created_at_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_deliveries_on_tenant_id_and_created_at_and_id ON public.deliveries USING btree (tenant_id, created_at, id);


--
-- Name: index_delivery_attempts_on_delivery_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_delivery_attempts_on_delivery_id ON public.delivery_attempts USING btree (delivery_id);


--
-- Name: index_endpoints_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_endpoints_on_tenant_id ON public.endpoints USING btree (tenant_id);


--
-- Name: index_endpoints_on_tenant_id_and_created_at_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_endpoints_on_tenant_id_and_created_at_and_id ON public.endpoints USING btree (tenant_id, created_at, id);


--
-- Name: index_endpoints_on_tenant_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_endpoints_on_tenant_id_and_id ON public.endpoints USING btree (tenant_id, id);


--
-- Name: index_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_tenant_id ON public.events USING btree (tenant_id);


--
-- Name: index_events_on_tenant_id_and_created_at_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_tenant_id_and_created_at_and_id ON public.events USING btree (tenant_id, created_at, id);


--
-- Name: index_events_on_tenant_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_on_tenant_id_and_id ON public.events USING btree (tenant_id, id);


--
-- Name: index_events_on_tenant_id_and_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_on_tenant_id_and_idempotency_key ON public.events USING btree (tenant_id, idempotency_key);


--
-- Name: events events_are_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER events_are_immutable BEFORE DELETE OR UPDATE ON public.events FOR EACH ROW EXECUTE FUNCTION public.reject_event_mutation();


--
-- Name: deliveries deliveries_tenant_endpoint; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_tenant_endpoint FOREIGN KEY (tenant_id, endpoint_id) REFERENCES public.endpoints(tenant_id, id);


--
-- Name: deliveries deliveries_tenant_event; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_tenant_event FOREIGN KEY (tenant_id, event_id) REFERENCES public.events(tenant_id, id);


--
-- Name: endpoints fk_rails_430e742d27; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.endpoints
    ADD CONSTRAINT fk_rails_430e742d27 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: api_credentials fk_rails_64e90778f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_credentials
    ADD CONSTRAINT fk_rails_64e90778f0 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: events fk_rails_6844d4946c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_6844d4946c FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: deliveries fk_rails_718677f735; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT fk_rails_718677f735 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: delivery_attempts fk_rails_cd1ebe6965; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_attempts
    ADD CONSTRAINT fk_rails_cd1ebe6965 FOREIGN KEY (delivery_id) REFERENCES public.deliveries(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261024000000'),
('0');

