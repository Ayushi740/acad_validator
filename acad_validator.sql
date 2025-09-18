
DROP TRIGGER IF EXISTS trg_documents_auto_partition ON documents;
DROP TRIGGER IF EXISTS trg_audit_documents ON documents;

DROP FUNCTION IF EXISTS create_documents_partition(timestamptz);
DROP FUNCTION IF EXISTS trg_create_partition();
DROP FUNCTION IF EXISTS trg_documents_audit();
DROP FUNCTION IF EXISTS create_document(bigint, text, text, text, timestamptz);


CREATE TABLE IF NOT EXISTS users (
    user_id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL,
    role TEXT CHECK (role IN ('student','validator','admin')) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS documents_index (
    doc_id BIGSERIAL PRIMARY KEY,
    user_id BIGINT REFERENCES users(user_id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    status TEXT CHECK (status IN ('pending','verified','rejected','fraud')) DEFAULT 'pending',
    file_path TEXT NOT NULL,
    uploaded_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);


CREATE TABLE IF NOT EXISTS documents (
    doc_id BIGINT NOT NULL REFERENCES documents_index(doc_id) ON DELETE CASCADE,
    uploaded_at TIMESTAMPTZ NOT NULL
) PARTITION BY RANGE (uploaded_at);


CREATE OR REPLACE FUNCTION create_documents_partition(p_uploaded_at TIMESTAMPTZ)
RETURNS void AS $$
DECLARE
    partition_name TEXT;
    start_date TIMESTAMPTZ;
    end_date TIMESTAMPTZ;
BEGIN
    start_date := date_trunc('month', p_uploaded_at);
    end_date := start_date + interval '1 month';
    partition_name := 'documents_' || TO_CHAR(start_date, 'YYYY_MM');

    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF documents
         FOR VALUES FROM (%L) TO (%L);',
        partition_name, start_date, end_date
    );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION trg_create_partition()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM create_documents_partition(NEW.uploaded_at);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_documents_auto_partition
BEFORE INSERT ON documents
FOR EACH ROW
EXECUTE FUNCTION trg_create_partition();


CREATE TABLE IF NOT EXISTS documents_audit (
    audit_id BIGSERIAL PRIMARY KEY,
    doc_id BIGINT,
    action TEXT,
    changed_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION trg_documents_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO documents_audit(doc_id, action) VALUES (NEW.doc_id, 'INSERT');
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO documents_audit(doc_id, action) VALUES (NEW.doc_id, 'UPDATE');
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO documents_audit(doc_id, action) VALUES (OLD.doc_id, 'DELETE');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_documents
AFTER INSERT OR UPDATE OR DELETE ON documents
FOR EACH ROW
EXECUTE FUNCTION trg_documents_audit();


CREATE TABLE IF NOT EXISTS ocr_results (
    ocr_id BIGSERIAL PRIMARY KEY,
    doc_id BIGINT REFERENCES documents_index(doc_id) ON DELETE CASCADE,
    extracted_text TEXT,
    extracted_fields JSONB,
    processed_at TIMESTAMP DEFAULT NOW()
);


CREATE TABLE IF NOT EXISTS verified_data (
    verified_id BIGSERIAL PRIMARY KEY,
    doc_id BIGINT REFERENCES documents_index(doc_id) ON DELETE CASCADE,
    field_name TEXT,
    expected_value TEXT,
    verified_by BIGINT REFERENCES users(user_id),
    verified_at TIMESTAMP DEFAULT NOW()
);


CREATE TABLE IF NOT EXISTS validation_logs (
    log_id BIGSERIAL PRIMARY KEY,
    doc_id BIGINT REFERENCES documents_index(doc_id) ON DELETE CASCADE,
    validator_id BIGINT REFERENCES users(user_id),
    result TEXT CHECK (result IN ('match','mismatch','suspect')),
    checked_at TIMESTAMP DEFAULT NOW(),
    comments TEXT
);


CREATE TABLE IF NOT EXISTS fraud_flags (
    flag_id BIGSERIAL PRIMARY KEY,
    doc_id BIGINT REFERENCES documents_index(doc_id) ON DELETE CASCADE,
    reason TEXT NOT NULL,
    flagged_at TIMESTAMP DEFAULT NOW(),
    flagged_by BIGINT REFERENCES users(user_id)
);


CREATE OR REPLACE FUNCTION create_document(
    p_user_id BIGINT,
    p_title TEXT,
    p_status TEXT,
    p_file_path TEXT,
    p_uploaded_at TIMESTAMPTZ
) RETURNS BIGINT AS $$
DECLARE
    v_doc_id BIGINT;
BEGIN
    
    INSERT INTO documents_index (user_id, title, status, file_path, uploaded_at)
    VALUES (p_user_id, p_title, p_status, p_file_path, p_uploaded_at)
    RETURNING doc_id INTO v_doc_id;

    
    PERFORM create_documents_partition(p_uploaded_at);

    
    INSERT INTO documents (doc_id, uploaded_at)
    VALUES (v_doc_id, p_uploaded_at);

    RETURN v_doc_id;
END;
$$ LANGUAGE plpgsql;
