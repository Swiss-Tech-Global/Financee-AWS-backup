--
-- PostgreSQL database dump
--

\restrict 9Zd2NW5j6pFpC021EB3YkYOfLIDMucy1beDd1om2biOBwyNsgQXpOBAXohh7Km1

-- Dumped from database version 16.11 (Ubuntu 16.11-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.11 (Ubuntu 16.11-0ubuntu0.24.04.1)

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
-- Name: add_item_from_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.add_item_from_json(item_data jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO Items (
        item_name, 
        storage, 
        sale_price, 
        item_code, 
        category, 
        brand,
        created_at,
        updated_at
    )
    VALUES (
        item_data->>'item_name',
        COALESCE(item_data->>'storage', 'Main Warehouse'),          -- default storage
        COALESCE((item_data->>'sale_price')::NUMERIC, 0.00),        -- default 0.00
        NULLIF(item_data->>'item_code', ''),                        -- NULL if empty
        NULLIF(item_data->>'category', ''),                         -- optional
        NULLIF(item_data->>'brand', ''),                            -- optional
        COALESCE((item_data->>'created_at')::TIMESTAMP, NOW()),     -- default current time
        COALESCE((item_data->>'updated_at')::TIMESTAMP, NOW())      -- default current time
    );
END;
$$;


ALTER FUNCTION public.add_item_from_json(item_data jsonb) OWNER TO postgres;

--
-- Name: add_party_from_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.add_party_from_json(party_data jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party_type TEXT := TRIM(BOTH '"' FROM party_data->>'party_type');
    v_party_name TEXT := TRIM(BOTH '"' FROM party_data->>'party_name');
    v_opening_balance NUMERIC := COALESCE((party_data->>'opening_balance')::NUMERIC, 0);
    v_balance_type TEXT := COALESCE(party_data->>'balance_type', 'Debit');
    v_expense_account_id BIGINT;
BEGIN
    -- Handle Expense-type Party (auto-create its expense COA account)
    IF v_party_type = 'Expense' THEN
        -- Check if Expense account already exists in COA
        SELECT account_id INTO v_expense_account_id
        FROM ChartOfAccounts
        WHERE account_name ILIKE v_party_name
          AND account_type = 'Expense'
        LIMIT 1;

        -- Create a new Expense account if not found
        IF v_expense_account_id IS NULL THEN
            INSERT INTO ChartOfAccounts (
                account_code, account_name, account_type, parent_account, date_created
            )
            VALUES (
                CONCAT('EXP-', LPAD((SELECT COUNT(*) + 1 FROM ChartOfAccounts WHERE account_type='Expense')::TEXT, 4, '0')),
                v_party_name,
                'Expense',
                (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Expenses' LIMIT 1),
                CURRENT_TIMESTAMP
            )
            RETURNING account_id INTO v_expense_account_id;
        END IF;
    END IF;

    -- Insert into Parties table
    INSERT INTO Parties (
        party_name, party_type, contact_info, address,
        opening_balance, balance_type,
        ar_account_id, ap_account_id
    )
    VALUES (
        v_party_name,
        v_party_type,
        party_data->>'contact_info',
        party_data->>'address',
        v_opening_balance,
        v_balance_type,
        CASE 
            WHEN v_party_type IN ('Customer','Both','Expense') THEN 
                (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Accounts Receivable' LIMIT 1)
            ELSE NULL 
        END,
        CASE 
            WHEN v_party_type IN ('Vendor','Both') THEN 
                (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Accounts Payable' LIMIT 1)
            WHEN v_party_type = 'Expense' THEN 
                v_expense_account_id
            ELSE NULL 
        END
    );
END;
$$;


ALTER FUNCTION public.add_party_from_json(party_data jsonb) OWNER TO postgres;

--
-- Name: create_purchase(bigint, date, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_purchase(p_party_id bigint, p_invoice_date date, p_items jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_invoice_id BIGINT;
    v_purchase_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_item_id BIGINT;
    v_item JSONB;
    v_serial TEXT;
BEGIN
    -- 1. Create Purchase Invoice (header)
    INSERT INTO PurchaseInvoices(vendor_id, invoice_date, total_amount)
    VALUES (p_party_id, p_invoice_date, 0)
    RETURNING purchase_invoice_id INTO v_invoice_id;

    -- 2. Loop through items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Resolve item_id from item_name
        SELECT item_id INTO v_item_id
        FROM Items
        WHERE item_name = (v_item->>'item_name')
        LIMIT 1;

        IF v_item_id IS NULL THEN
            -- Optionally auto-create item if not found
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        -- Insert purchase item
        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (
            v_invoice_id,
            v_item_id,
            (v_item->>'qty')::INT,
            (v_item->>'unit_price')::NUMERIC
        )
        RETURNING purchase_item_id INTO v_purchase_item_id;

        -- Accumulate total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Insert purchase units (serials) into stock
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            INSERT INTO PurchaseUnits(purchase_item_id, serial_number, in_stock)
            VALUES (v_purchase_item_id, v_serial, TRUE);

            -- Insert stock movement (IN) for audit trail
            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'IN', 'PurchaseInvoice', v_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- 3. Update invoice total
    UPDATE PurchaseInvoices
    SET total_amount = v_total
    WHERE purchase_invoice_id = v_invoice_id;

    -- 4. Build Journal Entry (explicit, no trigger needed)
    PERFORM rebuild_purchase_journal(v_invoice_id);

    RETURN v_invoice_id;
END;
$$;


ALTER FUNCTION public.create_purchase(p_party_id bigint, p_invoice_date date, p_items jsonb) OWNER TO postgres;

--
-- Name: create_purchase_return(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_purchase_return(p_party_name text, p_serials jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party_id BIGINT;
    v_return_id BIGINT;
    v_serial TEXT;
    v_unit RECORD;
    v_total NUMERIC(14,2) := 0;
BEGIN
    -- 1. Find Vendor
    SELECT party_id INTO v_party_id
    FROM Parties
    WHERE party_name = p_party_name;

    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Vendor % not found', p_party_name;
    END IF;

    -- 2. Create Return Header
    INSERT INTO PurchaseReturns(vendor_id, return_date, total_amount)
    VALUES (v_party_id, CURRENT_DATE, 0)
    RETURNING purchase_return_id INTO v_return_id;

    -- 3. Process each serial
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT pu.unit_id, pu.serial_number, pi.item_id, pi.unit_price, p.vendor_id, p.purchase_invoice_id
        INTO v_unit
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in PurchaseUnits', v_serial;
        END IF;

        -- check if in stock
        IF NOT EXISTS (
            SELECT 1 FROM PurchaseUnits WHERE unit_id = v_unit.unit_id AND in_stock = TRUE
        ) THEN
            RAISE EXCEPTION 'Serial % is not currently in stock', v_serial;
        END IF;

        -- check vendor match
        IF v_unit.vendor_id <> v_party_id THEN
            RAISE EXCEPTION 'Serial % was purchased from a different vendor', v_serial;
        END IF;

        -- mark as returned (remove from stock)
        UPDATE PurchaseUnits 
        SET in_stock = FALSE 
        WHERE unit_id = v_unit.unit_id;

        -- log stock OUT
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'OUT', 'PurchaseReturn', v_return_id, 1);

        -- insert return line (✅ unit_price instead of cost_price)
        INSERT INTO PurchaseReturnItems(purchase_return_id, item_id, unit_price, serial_number)
        VALUES (v_return_id, v_unit.item_id, v_unit.unit_price, v_serial);

        -- accumulate total
        v_total := v_total + v_unit.unit_price;
    END LOOP;

    -- 4. Update header total
    UPDATE PurchaseReturns
    SET total_amount = v_total
    WHERE purchase_return_id = v_return_id;

    -- 5. Build Journal
    PERFORM rebuild_purchase_return_journal(v_return_id);

    RETURN v_return_id;
END;
$$;


ALTER FUNCTION public.create_purchase_return(p_party_name text, p_serials jsonb) OWNER TO postgres;

--
-- Name: create_sale(bigint, date, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_sale(p_party_id bigint, p_invoice_date date, p_items jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_invoice_id BIGINT;
    v_sales_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_unit_id BIGINT;
    v_serial TEXT;
    v_item_id BIGINT;
    v_item JSONB;
BEGIN
    -- 1. Create Invoice (header)
    INSERT INTO SalesInvoices(customer_id, invoice_date, total_amount)
    VALUES (p_party_id, p_invoice_date, 0)
    RETURNING sales_invoice_id INTO v_invoice_id;

    -- 2. Loop through items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Resolve item_id from item_name
        SELECT item_id INTO v_item_id
        FROM Items
        WHERE item_name = (v_item->>'item_name')
        LIMIT 1;

        IF v_item_id IS NULL THEN
            RAISE EXCEPTION 'Item "%" not found in Items table', (v_item->>'item_name');
        END IF;

        -- Insert sales item
        INSERT INTO SalesItems(sales_invoice_id, item_id, quantity, unit_price)
        VALUES (
            v_invoice_id,
            v_item_id,
            (v_item->>'qty')::INT,
            (v_item->>'unit_price')::NUMERIC
        )
        RETURNING sales_item_id INTO v_sales_item_id;

        -- Accumulate total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Insert sold units from serials
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            -- find unit_id for this serial
            SELECT unit_id INTO v_unit_id
            FROM PurchaseUnits
            WHERE serial_number = v_serial
              AND in_stock = TRUE
            LIMIT 1;

            IF v_unit_id IS NULL THEN
                RAISE EXCEPTION 'Serial % not found or already sold', v_serial;
            END IF;

            -- insert sold unit
            INSERT INTO SoldUnits(sales_item_id, unit_id, sold_price, status)
            VALUES (v_sales_item_id, v_unit_id, (v_item->>'unit_price')::NUMERIC, 'Sold');

            -- mark purchase unit as not in stock
            UPDATE PurchaseUnits
            SET in_stock = FALSE
            WHERE unit_id = v_unit_id;

            -- log stock movement (OUT)
            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'OUT', 'SalesInvoice', v_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- 3. Update invoice total
    UPDATE SalesInvoices
    SET total_amount = v_total
    WHERE sales_invoice_id = v_invoice_id;

    -- 4. Build Journal Entry (explicit, no trigger needed)
    PERFORM rebuild_sales_journal(v_invoice_id);

    RETURN v_invoice_id;
END;
$$;


ALTER FUNCTION public.create_sale(p_party_id bigint, p_invoice_date date, p_items jsonb) OWNER TO postgres;

--
-- Name: create_sale_return(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_sale_return(p_party_name text, p_serials jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party_id BIGINT;
    v_return_id BIGINT;
    v_serial TEXT;
    v_unit RECORD;
    v_total NUMERIC(14,2) := 0;
    v_cost NUMERIC(14,2) := 0;
BEGIN
    -- 1. Find Customer
    SELECT party_id INTO v_party_id
    FROM Parties
    WHERE party_name = p_party_name;

    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Customer % not found', p_party_name;
    END IF;

    -- 2. Create Return Header
    INSERT INTO SalesReturns(customer_id, return_date, total_amount)
    VALUES (v_party_id, CURRENT_DATE, 0)
    RETURNING sales_return_id INTO v_return_id;

    -- 3. Process each serial
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT su.sold_unit_id, su.unit_id, su.sold_price, si.item_id,
               si.sales_invoice_id, pu.serial_number, pi.unit_price, s.customer_id
        INTO v_unit
        FROM SoldUnits su
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in SoldUnits', v_serial;
        END IF;

        -- check customer match
        IF v_unit.customer_id <> v_party_id THEN
            RAISE EXCEPTION 'Serial % was not sold to %', v_serial, p_party_name;
        END IF;

        -- mark sold unit as returned
        UPDATE SoldUnits SET status = 'Returned' WHERE sold_unit_id = v_unit.sold_unit_id;

        -- restore stock
        UPDATE PurchaseUnits SET in_stock = TRUE WHERE unit_id = v_unit.unit_id;

        -- log stock IN
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'IN', 'SalesReturn', v_return_id, 1);

        -- insert return line item
        INSERT INTO SalesReturnItems(sales_return_id, item_id, sold_price, cost_price, serial_number)
        VALUES (v_return_id, v_unit.item_id, v_unit.sold_price, v_unit.unit_price, v_serial);

        -- accumulate totals
        v_total := v_total + v_unit.sold_price;
        v_cost := v_cost + v_unit.unit_price;
    END LOOP;

    -- 4. Update return total
    UPDATE SalesReturns
    SET total_amount = v_total
    WHERE sales_return_id = v_return_id;

	-- Build Journal
	PERFORM rebuild_sales_return_journal(v_return_id);

    RETURN v_return_id;
END;
$$;


ALTER FUNCTION public.create_sale_return(p_party_name text, p_serials jsonb) OWNER TO postgres;

--
-- Name: delete_payment(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_payment(p_payment_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM Payments WHERE payment_id = p_payment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Payment ID % not found', p_payment_id;
    END IF;

    RETURN jsonb_build_object(
        'status','success',
        'message','Payment deleted successfully',
        'payment_id',p_payment_id
    );
END;
$$;


ALTER FUNCTION public.delete_payment(p_payment_id bigint) OWNER TO postgres;

--
-- Name: delete_purchase(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_purchase(p_invoice_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
    j_id BIGINT;
BEGIN
    -- 1. Capture the related journal_id (if any)
    SELECT journal_id INTO j_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id = p_invoice_id;

    -- 2. Log stock OUT movements before deleting
    FOR rec IN
        SELECT pu.serial_number, pi.item_id, pu.purchase_item_id
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pi.purchase_item_id = pu.purchase_item_id
        WHERE pi.purchase_invoice_id = p_invoice_id
    LOOP
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'OUT', 'PurchaseInvoice-Delete', p_invoice_id, 1);
    END LOOP;

    -- 3. Delete purchase units (serials)
    DELETE FROM PurchaseUnits
    WHERE purchase_item_id IN (
        SELECT purchase_item_id FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id
    );

    -- 4. Delete purchase items
    DELETE FROM PurchaseItems
    WHERE purchase_invoice_id = p_invoice_id;

    -- 5. Delete journal lines + journal entry if exists
    IF j_id IS NOT NULL THEN
        DELETE FROM JournalLines WHERE journal_id = j_id;
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- 6. Delete the purchase invoice itself
    DELETE FROM PurchaseInvoices
    WHERE purchase_invoice_id = p_invoice_id;

END;
$$;


ALTER FUNCTION public.delete_purchase(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: delete_purchase_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_purchase_return(p_return_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
    v_vendor_id BIGINT;
    v_unit_vendor_id BIGINT;
    v_journal_id BIGINT;
BEGIN
    -- 1. Get vendor id from return header
    SELECT vendor_id, journal_id
    INTO v_vendor_id, v_journal_id
    FROM PurchaseReturns
    WHERE purchase_return_id = p_return_id;

    IF v_vendor_id IS NULL THEN
        RAISE EXCEPTION 'Purchase Return % not found', p_return_id;
    END IF;

    -- 2. Restore stock for returned items
    FOR rec IN
        SELECT serial_number, item_id
        FROM PurchaseReturnItems
        WHERE purchase_return_id = p_return_id
    LOOP
        -- fetch the vendor of the original purchase for safety
        SELECT p.vendor_id
        INTO v_unit_vendor_id
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        WHERE pu.serial_number = rec.serial_number;

        IF v_unit_vendor_id IS DISTINCT FROM v_vendor_id THEN
            RAISE EXCEPTION 'Serial % does not belong to vendor % (return %)', 
                rec.serial_number, v_vendor_id, p_return_id;
        END IF;

        -- restore in stock
        UPDATE PurchaseUnits
        SET in_stock = TRUE
        WHERE serial_number = rec.serial_number;

        -- log stock IN
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'IN', 'PurchaseReturn-Delete', p_return_id, 1);
    END LOOP;

    -- 3. Remove journal (if exists)
    IF v_journal_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = v_journal_id;
    END IF;

    -- 4. Delete return items
    DELETE FROM PurchaseReturnItems WHERE purchase_return_id = p_return_id;

    -- 5. Delete return header
    DELETE FROM PurchaseReturns WHERE purchase_return_id = p_return_id;
END;
$$;


ALTER FUNCTION public.delete_purchase_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: delete_receipt(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_receipt(p_receipt_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM Receipts WHERE receipt_id = p_receipt_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receipt ID % not found', p_receipt_id;
    END IF;

    RETURN jsonb_build_object(
        'status','success',
        'message','Receipt deleted successfully',
        'receipt_id',p_receipt_id
    );
END;
$$;


ALTER FUNCTION public.delete_receipt(p_receipt_id bigint) OWNER TO postgres;

--
-- Name: delete_sale(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_sale(p_invoice_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
    v_journal_id BIGINT;
BEGIN
    -- 1. Restore stock for all sold units of this sale
    FOR rec IN
        SELECT su.unit_id, pu.serial_number, si.item_id
        FROM SoldUnits su
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        WHERE si.sales_invoice_id = p_invoice_id
    LOOP
        -- restore stock
        UPDATE PurchaseUnits
        SET in_stock = TRUE
        WHERE unit_id = rec.unit_id;

        -- log stock movement (IN)
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'IN', 'SalesInvoice-Delete', p_invoice_id, 1);
    END LOOP;

    -- 2. Delete associated journal entries (accounting)
    SELECT journal_id INTO v_journal_id
    FROM SalesInvoices
    WHERE sales_invoice_id = p_invoice_id;

    IF v_journal_id IS NOT NULL THEN
        DELETE FROM JournalLines WHERE journal_id = v_journal_id;
        DELETE FROM JournalEntries WHERE journal_id = v_journal_id;
    END IF;

    -- 3. Delete the invoice (cascade removes SalesItems + SoldUnits)
    DELETE FROM SalesInvoices
    WHERE sales_invoice_id = p_invoice_id;

END;
$$;


ALTER FUNCTION public.delete_sale(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: delete_sale_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_sale_return(p_return_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
	v_journal_id BIGINT;
BEGIN
    -- 1. Revert each returned unit
    FOR rec IN
        SELECT sri.serial_number, sri.item_id
        FROM SalesReturnItems sri
        WHERE sri.sales_return_id = p_return_id
    LOOP
        -- mark sold unit back as Sold
        UPDATE SoldUnits
        SET status = 'Sold'
        WHERE unit_id = (
            SELECT unit_id
            FROM PurchaseUnits
            WHERE serial_number = rec.serial_number
            LIMIT 1
        );

        -- remove from stock again
        UPDATE PurchaseUnits
        SET in_stock = FALSE
        WHERE serial_number = rec.serial_number;

        -- log stock OUT
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'OUT', 'SalesReturn-Delete', p_return_id, 1);
    END LOOP;

	-- 2. Remove journal (if exists)
    SELECT journal_id INTO v_journal_id
    FROM SalesReturns
    WHERE sales_return_id = p_return_id;

	IF v_journal_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = v_journal_id;
    END IF;

    -- 2. Delete return items
    DELETE FROM SalesReturnItems WHERE sales_return_id = p_return_id;

    -- 4. Delete return header (triggers remove journal)
    DELETE FROM SalesReturns WHERE sales_return_id = p_return_id;
END;
$$;


ALTER FUNCTION public.delete_sale_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: detailed_ledger(text, date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.detailed_ledger(p_party_name text, p_start_date date, p_end_date date) RETURNS TABLE(entry_date date, journal_id bigint, description text, party_name text, account_type text, debit numeric, credit numeric, running_balance numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH party_ledger AS (
        SELECT 
            je.entry_date AS entry_date,
            je.journal_id AS journal_id,
            je.description::TEXT AS description,
            p.party_name::TEXT AS party_name,                
            a.account_name::TEXT AS account_name,               
            jl.debit AS debit,
            jl.credit AS credit,
            (jl.debit - jl.credit) AS amount
        FROM JournalLines jl
        JOIN JournalEntries je ON jl.journal_id = je.journal_id
        JOIN ChartOfAccounts a ON jl.account_id = a.account_id
        LEFT JOIN Parties p ON jl.party_id = p.party_id   
        WHERE 
            p.party_name = p_party_name
            AND je.entry_date BETWEEN p_start_date AND p_end_date
    )
    SELECT 
        pl.entry_date,
        pl.journal_id,
        pl.description,
        pl.party_name,
        pl.account_name AS account_type,
        pl.debit,
        pl.credit,
        SUM(pl.amount) OVER (ORDER BY pl.entry_date, pl.journal_id ROWS UNBOUNDED PRECEDING) AS running_balance
    FROM party_ledger pl
    ORDER BY pl.entry_date, pl.journal_id;
END;
$$;


ALTER FUNCTION public.detailed_ledger(p_party_name text, p_start_date date, p_end_date date) OWNER TO postgres;

--
-- Name: get_current_purchase(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_current_purchase(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'purchase_invoice_id', pi.purchase_invoice_id,
        'Party', p.party_name,
        'invoice_date', pi.invoice_date,
        'total_amount', pi.total_amount,
        'description', je.description,
        'items', (
            SELECT json_agg(
                json_build_object(
                    'item_name', i.item_name,
                    'qty', pi2.quantity,
                    'unit_price', pi2.unit_price,
                    'serials', (
                        SELECT json_agg(pu.serial_number)
                        FROM PurchaseUnits pu
                        WHERE pu.purchase_item_id = pi2.purchase_item_id
                    )
                )
            )
            FROM PurchaseItems pi2
            JOIN Items i ON i.item_id = pi2.item_id
            WHERE pi2.purchase_invoice_id = pi.purchase_invoice_id
        )
    )
    INTO result
    FROM PurchaseInvoices pi
    JOIN Parties p ON p.party_id = pi.vendor_id
    LEFT JOIN JournalEntries je ON je.journal_id = pi.journal_id
    WHERE pi.purchase_invoice_id = p_invoice_id;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_current_purchase(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: get_current_purchase_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_current_purchase_return(p_return_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'purchase_return_id', pr.purchase_return_id,
        'Vendor', pa.party_name,
        'return_date', pr.return_date,
        'total_amount', pr.total_amount,
        'description', je.description,
        'items', (
            SELECT json_agg(
                json_build_object(
                    'item_name', i.item_name,
                    'unit_price', pri.unit_price,
                    'serial_number', pri.serial_number
                )
            )
            FROM PurchaseReturnItems pri
            JOIN Items i ON i.item_id = pri.item_id
            WHERE pri.purchase_return_id = pr.purchase_return_id
        )
    )
    INTO result
    FROM PurchaseReturns pr
    JOIN Parties pa ON pa.party_id = pr.vendor_id
    LEFT JOIN JournalEntries je ON je.journal_id = pr.journal_id
    WHERE pr.purchase_return_id = p_return_id;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_current_purchase_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: get_current_sale(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_current_sale(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'sales_invoice_id', si.sales_invoice_id,
        'Party', p.party_name,
        'invoice_date', si.invoice_date,
        'total_amount', si.total_amount,
        'description', je.description,
        'items', (
            SELECT json_agg(
                json_build_object(
                    'item_name', i.item_name,
                    'qty', s_items.quantity,
                    'unit_price', s_items.unit_price,
                    'serials', (
                        SELECT json_agg(pu.serial_number)
                        FROM SoldUnits su
                        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
                        WHERE su.sales_item_id = s_items.sales_item_id
                    )
                )
            )
            FROM SalesItems s_items
            JOIN Items i ON i.item_id = s_items.item_id
            WHERE s_items.sales_invoice_id = si.sales_invoice_id
        )
    )
    INTO result
    FROM SalesInvoices si
    JOIN Parties p ON p.party_id = si.customer_id
    LEFT JOIN JournalEntries je ON je.journal_id = si.journal_id
    WHERE si.sales_invoice_id = p_invoice_id;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_current_sale(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: get_current_sales_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_current_sales_return(p_return_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'sales_return_id', sr.sales_return_id,
        'Customer', pa.party_name,
        'return_date', sr.return_date,
        'total_amount', sr.total_amount,
        'description', je.description,
        'items', (
            SELECT json_agg(
                json_build_object(
                    'item_name', i.item_name,
                    'sold_price', sri.sold_price,
                    'cost_price', sri.cost_price,
                    'serial_number', sri.serial_number
                )
            )
            FROM SalesReturnItems sri
            JOIN Items i ON i.item_id = sri.item_id
            WHERE sri.sales_return_id = sr.sales_return_id
        )
    )
    INTO result
    FROM SalesReturns sr
    JOIN Parties pa ON pa.party_id = sr.customer_id
    LEFT JOIN JournalEntries je ON je.journal_id = sr.journal_id
    WHERE sr.sales_return_id = p_return_id;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_current_sales_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: get_expense_party_balances_json(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_expense_party_balances_json() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_agg(
               jsonb_build_object(
                   'name', name,
                   'balance', balance
               )
           )
    INTO result
    FROM vw_trial_balance
    WHERE code IS NULL  -- only parties (not chart of accounts)
      AND type = 'Expense Party'  -- specifically Expense Party
      AND balance <> 0;  -- optional: skip zero balances

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_expense_party_balances_json() OWNER TO postgres;

--
-- Name: get_item_by_name(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_item_by_name(p_item_name text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT COALESCE(
        jsonb_agg(to_jsonb(i) - 'updated_at' - 'created_at'),  -- convert rows to JSON array
        '[]'::jsonb
    )
    INTO result
    FROM Items i
    WHERE i.item_name ILIKE p_item_name;   -- case-insensitive match

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_item_by_name(p_item_name text) OWNER TO postgres;

--
-- Name: get_item_names_like(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_item_names_like(search_term text) RETURNS TABLE(item_name text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT item_name
    FROM items
    WHERE UPPER(item_name) LIKE search_term || '%';
END;
$$;


ALTER FUNCTION public.get_item_names_like(search_term text) OWNER TO postgres;

--
-- Name: get_items_json(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_items_json() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_agg(
               jsonb_build_object(
                   'item_name', item_name,
                   'brand', brand
               )
           )
    INTO result
    FROM Items;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_items_json() OWNER TO postgres;

--
-- Name: get_last_20_payments_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_20_payments_json(p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party TEXT;
    result  JSONB;
BEGIN
    -- Extract optional party filter
    v_party := p_data->>'party_name';

    SELECT jsonb_agg(row_data)
    INTO result
    FROM (
        SELECT to_jsonb(p) || jsonb_build_object('party_name', pt.party_name) AS row_data
        FROM Payments p
        JOIN Parties pt ON pt.party_id = p.party_id
        WHERE (v_party IS NULL OR pt.party_name ILIKE v_party)
        ORDER BY p.payment_date DESC, p.payment_id DESC
        LIMIT 20
    ) sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_last_20_payments_json(p_data jsonb) OWNER TO postgres;

--
-- Name: get_last_20_receipts_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_20_receipts_json(p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party TEXT;
    result  JSONB;
BEGIN
    v_party := p_data->>'party_name';

    SELECT jsonb_agg(row_data)
    INTO result
    FROM (
        SELECT to_jsonb(r) || jsonb_build_object('party_name', pt.party_name) AS row_data
        FROM Receipts r
        JOIN Parties pt ON pt.party_id = r.party_id
        WHERE (v_party IS NULL OR pt.party_name ILIKE v_party)
        ORDER BY r.receipt_date DESC, r.receipt_id DESC
        LIMIT 20
    ) sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_last_20_receipts_json(p_data jsonb) OWNER TO postgres;

--
-- Name: get_last_payment(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_payment() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(p) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    ORDER BY p.payment_id DESC
    LIMIT 1;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_last_payment() OWNER TO postgres;

--
-- Name: get_last_purchase(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_purchase() RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT purchase_invoice_id INTO last_id
    FROM PurchaseInvoices
    ORDER BY purchase_invoice_id DESC
    LIMIT 1;

    RETURN get_current_purchase(last_id);
END;
$$;


ALTER FUNCTION public.get_last_purchase() OWNER TO postgres;

--
-- Name: get_last_purchase_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_purchase_id() RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT purchase_invoice_id
    INTO last_id
    FROM PurchaseInvoices
    ORDER BY purchase_invoice_id DESC
    LIMIT 1;

    RETURN last_id;
END;
$$;


ALTER FUNCTION public.get_last_purchase_id() OWNER TO postgres;

--
-- Name: get_last_purchase_return(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_purchase_return() RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT purchase_return_id INTO last_id
    FROM PurchaseReturns
    ORDER BY purchase_return_id DESC
    LIMIT 1;

    RETURN get_current_purchase_return(last_id);
END;
$$;


ALTER FUNCTION public.get_last_purchase_return() OWNER TO postgres;

--
-- Name: get_last_purchase_return_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_purchase_return_id() RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT purchase_return_id
    INTO last_id
    FROM PurchaseReturns
    ORDER BY purchase_return_id DESC
    LIMIT 1;

    RETURN last_id;
END;
$$;


ALTER FUNCTION public.get_last_purchase_return_id() OWNER TO postgres;

--
-- Name: get_last_receipt(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_receipt() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(r) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    ORDER BY r.receipt_id DESC
    LIMIT 1;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_last_receipt() OWNER TO postgres;

--
-- Name: get_last_sale(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_sale() RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT sales_invoice_id INTO last_id
    FROM SalesInvoices
    ORDER BY sales_invoice_id DESC
    LIMIT 1;

    RETURN get_current_sale(last_id);
END;
$$;


ALTER FUNCTION public.get_last_sale() OWNER TO postgres;

--
-- Name: get_last_sale_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_sale_id() RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT sales_invoice_id
    INTO last_id
    FROM SalesInvoices
    ORDER BY sales_invoice_id DESC
    LIMIT 1;

    RETURN last_id;
END;
$$;


ALTER FUNCTION public.get_last_sale_id() OWNER TO postgres;

--
-- Name: get_last_sales_return(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_sales_return() RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT sales_return_id INTO last_id
    FROM SalesReturns
    ORDER BY sales_return_id DESC
    LIMIT 1;

    RETURN get_current_sales_return(last_id);
END;
$$;


ALTER FUNCTION public.get_last_sales_return() OWNER TO postgres;

--
-- Name: get_last_sales_return_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_sales_return_id() RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT sales_return_id
    INTO last_id
    FROM SalesReturns
    ORDER BY sales_return_id DESC
    LIMIT 1;

    RETURN last_id;
END;
$$;


ALTER FUNCTION public.get_last_sales_return_id() OWNER TO postgres;

--
-- Name: get_next_payment(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_next_payment(p_payment_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(p) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    WHERE p.payment_id > p_payment_id
    ORDER BY p.payment_id ASC
    LIMIT 1;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_next_payment(p_payment_id bigint) OWNER TO postgres;

--
-- Name: get_next_purchase(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_next_purchase(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    next_id BIGINT;
BEGIN
    SELECT purchase_invoice_id INTO next_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id > p_invoice_id
    ORDER BY purchase_invoice_id ASC
    LIMIT 1;

    IF next_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_purchase(next_id);
END;
$$;


ALTER FUNCTION public.get_next_purchase(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: get_next_purchase_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_next_purchase_return(p_return_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    next_id BIGINT;
BEGIN
    SELECT purchase_return_id INTO next_id
    FROM PurchaseReturns
    WHERE purchase_return_id > p_return_id
    ORDER BY purchase_return_id ASC
    LIMIT 1;

    IF next_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_purchase_return(next_id);
END;
$$;


ALTER FUNCTION public.get_next_purchase_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: get_next_receipt(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_next_receipt(p_receipt_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(r) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    WHERE r.receipt_id > p_receipt_id
    ORDER BY r.receipt_id ASC
    LIMIT 1;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_next_receipt(p_receipt_id bigint) OWNER TO postgres;

--
-- Name: get_next_sale(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_next_sale(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    next_id BIGINT;
BEGIN
    SELECT sales_invoice_id INTO next_id
    FROM SalesInvoices
    WHERE sales_invoice_id > p_invoice_id
    ORDER BY sales_invoice_id ASC
    LIMIT 1;

    IF next_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_sale(next_id);
END;
$$;


ALTER FUNCTION public.get_next_sale(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: get_next_sales_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_next_sales_return(p_return_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    next_id BIGINT;
BEGIN
    SELECT sales_return_id INTO next_id
    FROM SalesReturns
    WHERE sales_return_id > p_return_id
    ORDER BY sales_return_id ASC
    LIMIT 1;

    IF next_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_sales_return(next_id);
END;
$$;


ALTER FUNCTION public.get_next_sales_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: get_parties_json(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_parties_json() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_agg(
               jsonb_build_object(
                   'party_name', party_name,
                   'party_type', party_type
               )
           )
    INTO result
    FROM Parties;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_parties_json() OWNER TO postgres;

--
-- Name: get_party_balances_json(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_party_balances_json() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_agg(
               jsonb_build_object(
                   'name', name,
                   'balance', balance
               )
           )
    INTO result
    FROM vw_trial_balance
    WHERE code IS NULL  -- only parties (not chart of accounts)
      AND type NOT ILIKE '%Expense%'  -- exclude expense parties if any
      AND balance <> 0;  -- optional: skip zero balances

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_party_balances_json() OWNER TO postgres;

--
-- Name: get_party_by_name(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_party_by_name(p_name text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(p)
    INTO result
    FROM Parties p
    WHERE LOWER(p.party_name) = LOWER(p_name)
    LIMIT 1;

    IF result IS NULL THEN
        RETURN '[]'::jsonb;
    END IF;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_party_by_name(p_name text) OWNER TO postgres;

--
-- Name: get_payment_details(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_payment_details(p_payment_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(p) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    WHERE p.payment_id = p_payment_id;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_payment_details(p_payment_id bigint) OWNER TO postgres;

--
-- Name: get_payments_by_date_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_payments_by_date_json(p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_start DATE;
    v_end   DATE;
    v_party TEXT;
    result  JSONB;
BEGIN
    -- Extract from JSON
    v_start := (p_data->>'start_date')::DATE;
    v_end   := (p_data->>'end_date')::DATE;
    v_party := p_data->>'party_name';

    IF v_start IS NULL OR v_end IS NULL THEN
        RAISE EXCEPTION 'Both start_date and end_date must be provided in JSON';
    END IF;

    SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object('party_name', pt.party_name) 
                     ORDER BY p.payment_date DESC, p.payment_id DESC)
    INTO result
    FROM Payments p
    JOIN Parties pt ON pt.party_id = p.party_id
    WHERE p.payment_date BETWEEN v_start AND v_end
      AND (v_party IS NULL OR pt.party_name ILIKE v_party);

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_payments_by_date_json(p_data jsonb) OWNER TO postgres;

--
-- Name: get_previous_payment(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_previous_payment(p_payment_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(p) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    WHERE p.payment_id < p_payment_id
    ORDER BY p.payment_id DESC
    LIMIT 1;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_previous_payment(p_payment_id bigint) OWNER TO postgres;

--
-- Name: get_previous_purchase(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_previous_purchase(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    prev_id BIGINT;
BEGIN
    SELECT purchase_invoice_id INTO prev_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id < p_invoice_id
    ORDER BY purchase_invoice_id DESC
    LIMIT 1;

    IF prev_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_purchase(prev_id);
END;
$$;


ALTER FUNCTION public.get_previous_purchase(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: get_previous_purchase_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_previous_purchase_return(p_return_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    prev_id BIGINT;
BEGIN
    SELECT purchase_return_id INTO prev_id
    FROM PurchaseReturns
    WHERE purchase_return_id < p_return_id
    ORDER BY purchase_return_id DESC
    LIMIT 1;

    IF prev_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_purchase_return(prev_id);
END;
$$;


ALTER FUNCTION public.get_previous_purchase_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: get_previous_receipt(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_previous_receipt(p_receipt_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(r) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    WHERE r.receipt_id < p_receipt_id
    ORDER BY r.receipt_id DESC
    LIMIT 1;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_previous_receipt(p_receipt_id bigint) OWNER TO postgres;

--
-- Name: get_previous_sale(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_previous_sale(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    prev_id BIGINT;
BEGIN
    SELECT sales_invoice_id INTO prev_id
    FROM SalesInvoices
    WHERE sales_invoice_id < p_invoice_id
    ORDER BY sales_invoice_id DESC
    LIMIT 1;

    IF prev_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_sale(prev_id);
END;
$$;


ALTER FUNCTION public.get_previous_sale(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: get_previous_sales_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_previous_sales_return(p_return_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    prev_id BIGINT;
BEGIN
    SELECT sales_return_id INTO prev_id
    FROM SalesReturns
    WHERE sales_return_id < p_return_id
    ORDER BY sales_return_id DESC
    LIMIT 1;

    IF prev_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_sales_return(prev_id);
END;
$$;


ALTER FUNCTION public.get_previous_sales_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: get_purchase_return_summary(date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_purchase_return_summary(p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL THEN
        -- 🧾 Case 1: Returns between given dates (latest first)
        SELECT json_agg(p ORDER BY p.return_date DESC)
        INTO result
        FROM (
            SELECT
                pr.purchase_return_id,
                pr.return_date,
                pa.party_name AS vendor,
                pr.total_amount
            FROM PurchaseReturns pr
            JOIN Parties pa ON pr.vendor_id = pa.party_id
            WHERE pr.return_date BETWEEN p_start_date AND p_end_date
            ORDER BY pr.return_date DESC
        ) AS p;

    ELSE
        -- 🧾 Case 2: Last 20 purchase returns (latest first)
        SELECT json_agg(p ORDER BY p.return_date DESC)
        INTO result
        FROM (
            SELECT
                pr.purchase_return_id,
                pr.return_date,
                pa.party_name AS vendor,
                pr.total_amount
            FROM PurchaseReturns pr
            JOIN Parties pa ON pr.vendor_id = pa.party_id
            ORDER BY pr.return_date DESC
            LIMIT 20
        ) AS p;
    END IF;

    RETURN COALESCE(result, '[]'::json);
END;
$$;


ALTER FUNCTION public.get_purchase_return_summary(p_start_date date, p_end_date date) OWNER TO postgres;

--
-- Name: get_purchase_summary(date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_purchase_summary(p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL THEN
        -- 🧾 Case 1: Purchases between given dates (latest first)
        SELECT json_agg(p ORDER BY p.invoice_date DESC)
        INTO result
        FROM (
            SELECT
                pi.purchase_invoice_id,
                pi.invoice_date,
                pa.party_name AS vendor,
                pi.total_amount
            FROM PurchaseInvoices pi
            JOIN Parties pa ON pi.vendor_id = pa.party_id
            WHERE pi.invoice_date BETWEEN p_start_date AND p_end_date
            ORDER BY pi.invoice_date DESC
        ) AS p;

    ELSE
        -- 🧾 Case 2: Last 20 purchases (latest first)
        SELECT json_agg(p ORDER BY p.invoice_date DESC)
        INTO result
        FROM (
            SELECT
                pi.purchase_invoice_id,
                pi.invoice_date,
                pa.party_name AS vendor,
                pi.total_amount
            FROM PurchaseInvoices pi
            JOIN Parties pa ON pi.vendor_id = pa.party_id
            ORDER BY pi.invoice_date DESC
            LIMIT 20
        ) AS p;
    END IF;

    RETURN COALESCE(result, '[]'::json);
END;
$$;


ALTER FUNCTION public.get_purchase_summary(p_start_date date, p_end_date date) OWNER TO postgres;

--
-- Name: get_receipt_details(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_receipt_details(p_receipt_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(r) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    WHERE r.receipt_id = p_receipt_id;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_receipt_details(p_receipt_id bigint) OWNER TO postgres;

--
-- Name: get_receipts_by_date_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_receipts_by_date_json(p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_start DATE;
    v_end   DATE;
    v_party TEXT;
    result  JSONB;
BEGIN
    v_start := (p_data->>'start_date')::DATE;
    v_end   := (p_data->>'end_date')::DATE;
    v_party := p_data->>'party_name';

    IF v_start IS NULL OR v_end IS NULL THEN
        RAISE EXCEPTION 'Both start_date and end_date must be provided in JSON';
    END IF;

    SELECT jsonb_agg(to_jsonb(r) || jsonb_build_object('party_name', pt.party_name) 
                     ORDER BY r.receipt_date DESC, r.receipt_id DESC)
    INTO result
    FROM Receipts r
    JOIN Parties pt ON pt.party_id = r.party_id
    WHERE r.receipt_date BETWEEN v_start AND v_end
      AND (v_party IS NULL OR pt.party_name ILIKE v_party);

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_receipts_by_date_json(p_data jsonb) OWNER TO postgres;

--
-- Name: get_sales_return_summary(date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_sales_return_summary(p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL THEN
        -- 📅 Filter by date range
        SELECT json_agg(p ORDER BY p.return_date DESC)
        INTO result
        FROM (
            SELECT
                sr.sales_return_id,
                sr.return_date,
                pa.party_name AS customer,
                sr.total_amount
            FROM SalesReturns sr
            JOIN Parties pa ON sr.customer_id = pa.party_id
            WHERE sr.return_date BETWEEN p_start_date AND p_end_date
            ORDER BY sr.return_date DESC
        ) AS p;
    ELSE
        -- 📅 Last 20 returns
        SELECT json_agg(p ORDER BY p.return_date DESC)
        INTO result
        FROM (
            SELECT
                sr.sales_return_id,
                sr.return_date,
                pa.party_name AS customer,
                sr.total_amount
            FROM SalesReturns sr
            JOIN Parties pa ON sr.customer_id = pa.party_id
            ORDER BY sr.return_date DESC
            LIMIT 20
        ) AS p;
    END IF;

    RETURN COALESCE(result, '[]'::json);
END;
$$;


ALTER FUNCTION public.get_sales_return_summary(p_start_date date, p_end_date date) OWNER TO postgres;

--
-- Name: get_sales_summary(date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_sales_summary(p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL THEN
        -- 🧾 Case 1: Sales between given dates (latest first)
        SELECT json_agg(p ORDER BY p.invoice_date DESC)
        INTO result
        FROM (
            SELECT
                si.sales_invoice_id,
                si.invoice_date,
                pa.party_name AS customer,
                si.total_amount
            FROM SalesInvoices si
            JOIN Parties pa ON si.customer_id = pa.party_id
            WHERE si.invoice_date BETWEEN p_start_date AND p_end_date
            ORDER BY si.invoice_date DESC
        ) AS p;

    ELSE
        -- 🧾 Case 2: Last 20 sales (latest first)
        SELECT json_agg(p ORDER BY p.invoice_date DESC)
        INTO result
        FROM (
            SELECT
                si.sales_invoice_id,
                si.invoice_date,
                pa.party_name AS customer,
                si.total_amount
            FROM SalesInvoices si
            JOIN Parties pa ON si.customer_id = pa.party_id
            ORDER BY si.invoice_date DESC
            LIMIT 20
        ) AS p;
    END IF;

    RETURN COALESCE(result, '[]'::json);
END;
$$;


ALTER FUNCTION public.get_sales_summary(p_start_date date, p_end_date date) OWNER TO postgres;

--
-- Name: get_serial_ledger(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_serial_ledger(p_serial text) RETURNS TABLE(serial_number text, item_name text, txn_date date, particulars text, reference text, qty_in integer, qty_out integer, balance integer, party_name text, purchase_price numeric, sale_price numeric, profit numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY

    WITH item_info AS (
        SELECT 
            pu.serial_number::text AS serial_number,
            i.item_name::text AS item_name
        FROM PurchaseUnits pu
        JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
        JOIN Items i ON pit.item_id = i.item_id
        WHERE pu.serial_number = p_serial
        LIMIT 1
    ),

    purchase AS (
        SELECT 
            pi.invoice_date AS dt,
            'Purchase'::text AS particulars,
            pi.purchase_invoice_id::text AS reference,
            1 AS qty_in,
            0 AS qty_out,
            p.party_name::text AS party_name,
            pit.unit_price AS purchase_price,
            NULL::numeric AS sale_price
        FROM PurchaseUnits pu
        JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
        JOIN PurchaseInvoices pi ON pit.purchase_invoice_id = pi.purchase_invoice_id
        JOIN Parties p ON pi.vendor_id = p.party_id
        WHERE pu.serial_number = p_serial
    ),

    purchase_return AS (
        SELECT
            pr.return_date AS dt,
            'Purchase Return'::text AS particulars,
            pr.purchase_return_id::text AS reference,
            0 AS qty_in,
            1 AS qty_out,
            p.party_name::text AS party_name,
            pri.unit_price AS purchase_price,
            NULL::numeric AS sale_price
        FROM PurchaseReturnItems pri
        JOIN PurchaseReturns pr ON pri.purchase_return_id = pr.purchase_return_id
        JOIN Parties p ON pr.vendor_id = p.party_id
        WHERE pri.serial_number = p_serial
    ),

    sale AS (
        SELECT 
            si.invoice_date AS dt,
            'Sale'::text AS particulars,
            si.sales_invoice_id::text AS reference,
            0 AS qty_in,
            1 AS qty_out,
            c.party_name::text AS party_name,
            pit.unit_price AS purchase_price,
            su.sold_price AS sale_price
        FROM SoldUnits su
        JOIN SalesItems sitm ON su.sales_item_id = sitm.sales_item_id
        JOIN SalesInvoices si ON sitm.sales_invoice_id = si.sales_invoice_id
        JOIN Parties c ON si.customer_id = c.party_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
        WHERE pu.serial_number = p_serial
    ),

    sales_return AS (
        SELECT
            sr.return_date AS dt,
            'Sales Return'::text AS particulars,
            sr.sales_return_id::text AS reference,
            1 AS qty_in,
            0 AS qty_out,
            c.party_name::text AS party_name,
            sri.cost_price AS purchase_price,
            sri.sold_price AS sale_price
        FROM SalesReturnItems sri
        JOIN SalesReturns sr ON sri.sales_return_id = sr.sales_return_id
        JOIN Parties c ON sr.customer_id = c.party_id
        WHERE sri.serial_number = p_serial
    )

    SELECT
        ii.serial_number,
        ii.item_name,
        l.dt AS txn_date,
        l.particulars,
        l.reference,
        l.qty_in,
        l.qty_out,
        CAST(SUM(l.qty_in - l.qty_out) OVER (ORDER BY l.dt, l.reference) AS INT) AS balance,
        l.party_name,
        l.purchase_price,
        l.sale_price,
        CASE 
            WHEN l.sale_price IS NOT NULL AND l.purchase_price IS NOT NULL 
            THEN l.sale_price - l.purchase_price
        END AS profit
    FROM (
        SELECT * FROM purchase
        UNION ALL SELECT * FROM purchase_return
        UNION ALL SELECT * FROM sale
        UNION ALL SELECT * FROM sales_return
    ) l
    CROSS JOIN item_info ii
    ORDER BY l.dt, l.reference;

END;
$$;


ALTER FUNCTION public.get_serial_ledger(p_serial text) OWNER TO postgres;

--
-- Name: get_serial_number_details(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_serial_number_details(serial text) RETURNS TABLE(serial_number character varying, item_name character varying, brand character varying, category character varying, purchase_invoice_id bigint, vendor_name character varying, purchase_date date, purchase_price numeric, in_stock boolean, sales_invoice_id bigint, customer_name character varying, sale_date date, sold_price numeric, current_status character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        pu.serial_number,
        i.item_name,
        i.brand,
        i.category,
        pi.purchase_invoice_id,
        p.party_name AS vendor_name,
        pi.invoice_date AS purchase_date,
        pit.unit_price AS purchase_price,
        pu.in_stock,
        si.sales_invoice_id,
        c.party_name AS customer_name,
        si.invoice_date AS sale_date,
        su.sold_price,
        COALESCE(su.status, CASE WHEN pu.in_stock THEN 'In Stock' ELSE 'Sold/Unknown' END) AS current_status
    FROM PurchaseUnits pu
    JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
    JOIN Items i ON pit.item_id = i.item_id
    JOIN PurchaseInvoices pi ON pit.purchase_invoice_id = pi.purchase_invoice_id
    JOIN Parties p ON pi.vendor_id = p.party_id
    LEFT JOIN SoldUnits su ON su.unit_id = pu.unit_id
    LEFT JOIN SalesItems si_itm ON su.sales_item_id = si_itm.sales_item_id
    LEFT JOIN SalesInvoices si ON si_itm.sales_invoice_id = si.sales_invoice_id
    LEFT JOIN Parties c ON si.customer_id = c.party_id
    WHERE pu.serial_number = serial;
END;
$$;


ALTER FUNCTION public.get_serial_number_details(serial text) OWNER TO postgres;

--
-- Name: get_trial_balance_json(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_trial_balance_json() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_agg(
               jsonb_build_object(
                   'name', name,
                   'balance', balance
               )
           )
    INTO result
    FROM vw_trial_balance;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_trial_balance_json() OWNER TO postgres;

--
-- Name: item_transaction_history(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.item_transaction_history(p_item_name text) RETURNS TABLE(item_name text, serial_number text, transaction_date date, transaction_type text, counterparty text, price numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH purchase_history AS (
        SELECT 
            i.item_id,
            i.item_name::TEXT AS item_name,
            pu.serial_number::TEXT AS serial_number,
            p.invoice_date AS transaction_date,
            'PURCHASE'::TEXT AS transaction_type,
            v.party_name::TEXT AS counterparty,
            pi.unit_price AS price
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        JOIN Items i ON pi.item_id = i.item_id
        JOIN Parties v ON p.vendor_id = v.party_id
        WHERE i.item_name ILIKE ('%' || p_item_name || '%')
    ),
    sale_history AS (
        SELECT 
            i.item_id,
            i.item_name::TEXT AS item_name,
            pu.serial_number::TEXT AS serial_number,
            s.invoice_date AS transaction_date,
            'SALE'::TEXT AS transaction_type,
            c.party_name::TEXT AS counterparty,
            su.sold_price AS price
        FROM SoldUnits su
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN Items i ON si.item_id = i.item_id
        JOIN Parties c ON s.customer_id = c.party_id
        WHERE i.item_name ILIKE ('%' || p_item_name || '%')
    )
    SELECT 
        ph.item_name,
        ph.serial_number,
        ph.transaction_date,
        ph.transaction_type,
        ph.counterparty,
        ph.price
    FROM (
        SELECT * FROM purchase_history
        UNION ALL
        SELECT * FROM sale_history
    ) AS ph
    ORDER BY ph.transaction_date, 
             ph.transaction_type DESC,   -- ensures PURCHASE before SALE if same date
             ph.serial_number;
END;
$$;


ALTER FUNCTION public.item_transaction_history(p_item_name text) OWNER TO postgres;

--
-- Name: item_transaction_history(text, date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.item_transaction_history(p_item_name text, p_from_date date DEFAULT NULL::date, p_to_date date DEFAULT NULL::date) RETURNS TABLE(item_name text, serial_number text, transaction_date date, transaction_type text, counterparty text, price numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH purchase_history AS (
        SELECT 
            i.item_id,
            i.item_name::TEXT AS item_name,
            pu.serial_number::TEXT AS serial_number,
            p.invoice_date AS transaction_date,
            'PURCHASE'::TEXT AS transaction_type,
            v.party_name::TEXT AS counterparty,
            pi.unit_price AS price
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        JOIN Items i ON pi.item_id = i.item_id
        JOIN Parties v ON p.vendor_id = v.party_id
        WHERE i.item_name ILIKE ('%' || p_item_name || '%')
          AND (p_from_date IS NULL OR p.invoice_date >= p_from_date)
          AND (p_to_date IS NULL OR p.invoice_date <= p_to_date)
    ),
    sale_history AS (
        SELECT 
            i.item_id,
            i.item_name::TEXT AS item_name,
            pu.serial_number::TEXT AS serial_number,
            s.invoice_date AS transaction_date,
            'SALE'::TEXT AS transaction_type,
            c.party_name::TEXT AS counterparty,
            su.sold_price AS price
        FROM SoldUnits su
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN Items i ON si.item_id = i.item_id
        JOIN Parties c ON s.customer_id = c.party_id
        WHERE i.item_name ILIKE ('%' || p_item_name || '%')
          AND (p_from_date IS NULL OR s.invoice_date >= p_from_date)
          AND (p_to_date IS NULL OR s.invoice_date <= p_to_date)
    )
    SELECT 
        ph.item_name,
        ph.serial_number,
        ph.transaction_date,
        ph.transaction_type,
        ph.counterparty,
        ph.price
    FROM (
        SELECT * FROM purchase_history
        UNION ALL
        SELECT * FROM sale_history
    ) AS ph
    ORDER BY ph.transaction_date, 
             ph.transaction_type DESC,   -- ensures PURCHASE before SALE if same date
             ph.serial_number;
END;
$$;


ALTER FUNCTION public.item_transaction_history(p_item_name text, p_from_date date, p_to_date date) OWNER TO postgres;

--
-- Name: make_payment(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.make_payment(p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party_id   BIGINT;
    v_account_id BIGINT;
    v_amount     NUMERIC(14,2);
    v_method     TEXT;
    v_reference  TEXT;
    v_desc       TEXT;
    v_date       DATE;
    v_id         BIGINT;
BEGIN
    -- Extract
    v_amount    := (p_data->>'amount')::NUMERIC;
    v_method    := p_data->>'method';
    v_reference := p_data->>'reference_no';
    v_desc      := p_data->>'description';
    v_date      := NULLIF(p_data->>'payment_date','')::DATE;

    IF v_amount IS NULL OR v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount: must be > 0';
    END IF;

    -- Get Vendor
    SELECT party_id INTO v_party_id
    FROM Parties
    WHERE party_name = p_data->>'party_name'
    LIMIT 1;

    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Vendor % not found', p_data->>'party_name';
    END IF;

    -- Always Cash for now
    SELECT account_id INTO v_account_id
    FROM ChartOfAccounts
    WHERE account_name = 'Cash';

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Cash account not found';
    END IF;

    -- Auto ref
    IF v_reference IS NULL OR v_reference = '' THEN
        v_reference := 'PMT-' || nextval('payments_ref_seq');
    END IF;

    -- Insert (use given date or default CURRENT_DATE)
    INSERT INTO Payments(party_id, account_id, amount, method, reference_no, description, payment_date)
    VALUES (v_party_id, v_account_id, v_amount, v_method, v_reference, v_desc, COALESCE(v_date, CURRENT_DATE))
    RETURNING payment_id INTO v_id;

    RETURN jsonb_build_object(
        'status','success',
        'message','Payment created successfully',
        'payment_id',v_id
    );
END;
$$;


ALTER FUNCTION public.make_payment(p_data jsonb) OWNER TO postgres;

--
-- Name: make_receipt(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.make_receipt(p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party_id   BIGINT;
    v_account_id BIGINT;
    v_amount     NUMERIC(14,2);
    v_method     TEXT;
    v_reference  TEXT;
    v_desc       TEXT;
    v_date       DATE;
    v_id         BIGINT;
BEGIN
    -- Extract
    v_amount    := (p_data->>'amount')::NUMERIC;
    v_method    := p_data->>'method';
    v_reference := p_data->>'reference_no';
    v_desc      := p_data->>'description';
    v_date      := NULLIF(p_data->>'receipt_date','')::DATE;

    IF v_amount IS NULL OR v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount: must be > 0';
    END IF;

    -- Get Customer
    SELECT party_id INTO v_party_id
    FROM Parties
    WHERE party_name = p_data->>'party_name'
    LIMIT 1;

    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Customer % not found', p_data->>'party_name';
    END IF;

    -- Always Cash for now
    SELECT account_id INTO v_account_id
    FROM ChartOfAccounts
    WHERE account_name = 'Cash';

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Cash account not found';
    END IF;

    -- Auto ref
    IF v_reference IS NULL OR v_reference = '' THEN
        v_reference := 'RCT-' || nextval('receipts_ref_seq');
    END IF;

    -- Insert
    INSERT INTO Receipts(party_id, account_id, amount, method, reference_no, description, receipt_date)
    VALUES (v_party_id, v_account_id, v_amount, v_method, v_reference, v_desc, COALESCE(v_date, CURRENT_DATE))
    RETURNING receipt_id INTO v_id;

    RETURN jsonb_build_object(
        'status','success',
        'message','Receipt created successfully',
        'receipt_id',v_id
    );
END;
$$;


ALTER FUNCTION public.make_receipt(p_data jsonb) OWNER TO postgres;

--
-- Name: rebuild_purchase_journal(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rebuild_purchase_journal(p_invoice_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    inv_acc BIGINT;
    party_acc BIGINT;
    v_total NUMERIC(14,2);
BEGIN
    -- 1. Remove old journal if exists
    SELECT journal_id INTO j_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id = p_invoice_id;

    IF j_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- 2. Get accounts
    SELECT account_id INTO inv_acc FROM ChartOfAccounts WHERE account_name='Inventory';
    SELECT ap_account_id INTO party_acc FROM Parties p
    JOIN PurchaseInvoices pi ON pi.vendor_id = p.party_id
    WHERE pi.purchase_invoice_id = p_invoice_id;

    -- 3. Get invoice total
    SELECT total_amount INTO v_total
    FROM PurchaseInvoices WHERE purchase_invoice_id = p_invoice_id;

    -- 4. Insert new journal entry
    INSERT INTO JournalEntries(entry_date, description)
    SELECT invoice_date, 'Purchase Invoice ' || purchase_invoice_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id = p_invoice_id
    RETURNING journal_id INTO j_id;

    -- 5. Update invoice with new journal_id
    UPDATE PurchaseInvoices
    SET journal_id = j_id
    WHERE purchase_invoice_id = p_invoice_id;

    -- 6. Debit Inventory
    INSERT INTO JournalLines(journal_id, account_id, debit)
    VALUES (j_id, inv_acc, v_total);

    -- 7. Credit Vendor (AP)
    INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
    VALUES (j_id, party_acc, (
        SELECT vendor_id FROM PurchaseInvoices WHERE purchase_invoice_id = p_invoice_id
    ), v_total);
END;
$$;


ALTER FUNCTION public.rebuild_purchase_journal(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: rebuild_purchase_return_journal(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rebuild_purchase_return_journal(p_return_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    inv_acc BIGINT;
    party_acc BIGINT;
    v_total NUMERIC(14,2);
    v_vendor_id BIGINT;
    v_date DATE;
BEGIN
    -- 1. Remove old journal if exists
    SELECT journal_id INTO j_id 
    FROM PurchaseReturns 
    WHERE purchase_return_id = p_return_id;

    IF j_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- 2. Get totals
    SELECT vendor_id, total_amount, return_date
    INTO v_vendor_id, v_total, v_date
    FROM PurchaseReturns 
    WHERE purchase_return_id = p_return_id;

    -- 3. Accounts
    SELECT account_id INTO inv_acc 
    FROM ChartOfAccounts 
    WHERE account_name='Inventory';

    SELECT ap_account_id INTO party_acc 
    FROM Parties 
    WHERE party_id = v_vendor_id;

    -- 4. New journal
    INSERT INTO JournalEntries(entry_date, description)
    VALUES (v_date, 'Purchase Return ' || p_return_id)
    RETURNING journal_id INTO j_id;

    UPDATE PurchaseReturns 
    SET journal_id = j_id 
    WHERE purchase_return_id = p_return_id;

    -- 5. Journal lines (with conditions)
    -- (1) Debit Vendor (reduce AP balance)
    IF v_total > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
        VALUES (j_id, party_acc, v_vendor_id, v_total);
    END IF;

    -- (2) Credit Inventory (stock reduced)
    IF v_total > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, credit)
        VALUES (j_id, inv_acc, v_total);
    END IF;
END;
$$;


ALTER FUNCTION public.rebuild_purchase_return_journal(p_return_id bigint) OWNER TO postgres;

--
-- Name: rebuild_sales_journal(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rebuild_sales_journal(p_invoice_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    rev_acc BIGINT;
    party_acc BIGINT;
    cogs_acc BIGINT;
    inv_acc BIGINT;
    total_cost NUMERIC(14,2);
    total_revenue NUMERIC(14,2);
    v_customer_id BIGINT;
    v_invoice_date DATE;
BEGIN
    -- 1. Get existing journal_id (if any)
    SELECT journal_id INTO j_id
    FROM SalesInvoices
    WHERE sales_invoice_id = p_invoice_id;

    -- 2. If exists, clear old lines + entry
    IF j_id IS NOT NULL THEN
        DELETE FROM JournalLines WHERE journal_id = j_id;
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- 3. Get invoice details
    SELECT s.customer_id, s.total_amount, s.invoice_date
    INTO v_customer_id, total_revenue, v_invoice_date
    FROM SalesInvoices s
    WHERE s.sales_invoice_id = p_invoice_id;

    -- 4. Get accounts
    SELECT account_id INTO rev_acc FROM ChartOfAccounts WHERE account_name='Sales Revenue';
    SELECT account_id INTO cogs_acc FROM ChartOfAccounts WHERE account_name='Cost of Goods Sold';
    SELECT account_id INTO inv_acc FROM ChartOfAccounts WHERE account_name='Inventory';
    SELECT ar_account_id INTO party_acc FROM Parties WHERE party_id = v_customer_id;

    -- 5. Insert new journal entry
    INSERT INTO JournalEntries(entry_date, description)
    VALUES (v_invoice_date, 'Sale Invoice ' || p_invoice_id)
    RETURNING journal_id INTO j_id;

    -- 6. Update invoice with new journal_id
    UPDATE SalesInvoices
    SET journal_id = j_id
    WHERE sales_invoice_id = p_invoice_id;

    -- (1) Debit Customer (AR)
    INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
    VALUES (j_id, party_acc, v_customer_id, total_revenue);

    -- (2) Credit Revenue
    INSERT INTO JournalLines(journal_id, account_id, credit)
    VALUES (j_id, rev_acc, total_revenue);

    -- (3) Debit COGS / Credit Inventory
    SELECT COALESCE(SUM(pi.unit_price),0) INTO total_cost
    FROM SoldUnits su
    JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
    JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
    JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
    WHERE si.sales_invoice_id = p_invoice_id;

    IF total_cost > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, debit)
        VALUES (j_id, cogs_acc, total_cost);

        INSERT INTO JournalLines(journal_id, account_id, credit)
        VALUES (j_id, inv_acc, total_cost);
    END IF;
END;
$$;


ALTER FUNCTION public.rebuild_sales_journal(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: rebuild_sales_return_journal(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rebuild_sales_return_journal(p_return_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    rev_acc BIGINT;
    cogs_acc BIGINT;
    inv_acc BIGINT;
    party_acc BIGINT;
    v_total NUMERIC(14,2);
    v_cost NUMERIC(14,2);
    v_customer_id BIGINT;
    v_date DATE;
BEGIN
    -- remove old journal
    SELECT journal_id INTO j_id FROM SalesReturns WHERE sales_return_id = p_return_id;
    IF j_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- totals
    SELECT customer_id, total_amount, return_date
    INTO v_customer_id, v_total, v_date
    FROM SalesReturns WHERE sales_return_id = p_return_id;

    SELECT COALESCE(SUM(cost_price),0) INTO v_cost
    FROM SalesReturnItems WHERE sales_return_id = p_return_id;

    -- accounts
    SELECT account_id INTO rev_acc FROM ChartOfAccounts WHERE account_name='Sales Revenue';
    SELECT account_id INTO cogs_acc FROM ChartOfAccounts WHERE account_name='Cost of Goods Sold';
    SELECT account_id INTO inv_acc FROM ChartOfAccounts WHERE account_name='Inventory';
    SELECT ar_account_id INTO party_acc FROM Parties WHERE party_id = v_customer_id;

    -- new journal
    INSERT INTO JournalEntries(entry_date, description)
    VALUES (v_date, 'Sales Return ' || p_return_id)
    RETURNING journal_id INTO j_id;

    UPDATE SalesReturns SET journal_id = j_id WHERE sales_return_id = p_return_id;

    -- (1) Debit Sales Revenue
    IF v_total > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, debit)
        VALUES (j_id, rev_acc, v_total);
    END IF;

    -- (2) Credit Customer AR
    IF v_total > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
        VALUES (j_id, party_acc, v_customer_id, v_total);
    END IF;

    -- (3) Debit Inventory
    IF v_cost > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, debit)
        VALUES (j_id, inv_acc, v_cost);
    END IF;

    -- (4) Credit COGS
    IF v_cost > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, credit)
        VALUES (j_id, cogs_acc, v_cost);
    END IF;
END;
$$;


ALTER FUNCTION public.rebuild_sales_return_journal(p_return_id bigint) OWNER TO postgres;

--
-- Name: sale_wise_profit(date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sale_wise_profit(p_from_date date, p_to_date date) RETURNS TABLE(sale_date date, serial_number text, item_name text, sale_price numeric, purchase_price numeric, profit_loss numeric, profit_loss_percent numeric, vendor_name text, purchase_date date)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH sold_serials AS (
        SELECT 
            su.sold_unit_id,
            su.sold_price,
            pu.serial_number::TEXT AS serial_number,
            si.sales_item_id,
            s.sales_invoice_id,
            s.invoice_date AS sale_date,
            i.item_name::TEXT AS item_name,
            i.item_code,
            i.brand,
            i.category,
            si.item_id
        FROM SoldUnits su
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN Items i ON si.item_id = i.item_id
        WHERE s.invoice_date BETWEEN p_from_date AND p_to_date
    ),
    purchased_serials AS (
        SELECT 
            pu.unit_id,
            pu.serial_number::TEXT AS serial_number,
            pi.purchase_item_id,
            p.purchase_invoice_id,
            p.invoice_date AS purchase_date,
            p.vendor_id,
            i.item_id,
            i.item_name::TEXT AS item_name,
            pi.unit_price AS purchase_price
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        JOIN Items i ON pi.item_id = i.item_id
    )
    SELECT 
        ss.sale_date,
        ss.serial_number,
        ss.item_name,
        ss.sold_price AS sale_price,
        ps.purchase_price,
        ROUND(ss.sold_price - ps.purchase_price, 2) AS profit_loss,
        CASE 
            WHEN ps.purchase_price > 0 THEN ROUND(((ss.sold_price - ps.purchase_price) / ps.purchase_price) * 100, 2)
            ELSE NULL
        END AS profit_loss_percent,
        v.party_name::TEXT AS vendor_name,
        ps.purchase_date
    FROM sold_serials ss
    LEFT JOIN purchased_serials ps 
        ON ss.serial_number = ps.serial_number
    LEFT JOIN Parties v 
        ON ps.vendor_id = v.party_id
    ORDER BY ss.sale_date, ss.item_name, ss.serial_number;
END;
$$;


ALTER FUNCTION public.sale_wise_profit(p_from_date date, p_to_date date) OWNER TO postgres;

--
-- Name: serial_exists_in_purchase_return(bigint, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.serial_exists_in_purchase_return(p_purchase_return_id bigint, p_serial_number text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN
    SELECT TRUE
    INTO v_exists
    FROM PurchaseReturnItems
    WHERE purchase_return_id = p_purchase_return_id
      AND serial_number = p_serial_number
    LIMIT 1;

    RETURN COALESCE(v_exists, FALSE);
END;
$$;


ALTER FUNCTION public.serial_exists_in_purchase_return(p_purchase_return_id bigint, p_serial_number text) OWNER TO postgres;

--
-- Name: serial_exists_in_sales_return(bigint, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.serial_exists_in_sales_return(p_sales_return_id bigint, p_serial_number text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN
    SELECT TRUE
    INTO v_exists
    FROM SalesReturnItems
    WHERE sales_return_id = p_sales_return_id
      AND serial_number = p_serial_number
    LIMIT 1;

    RETURN COALESCE(v_exists, FALSE);
END;
$$;


ALTER FUNCTION public.serial_exists_in_sales_return(p_sales_return_id bigint, p_serial_number text) OWNER TO postgres;

--
-- Name: trg_party_opening_balance(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trg_party_opening_balance() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    debit_acc BIGINT;
    credit_acc BIGINT;
    cap_acc BIGINT;
BEGIN
    IF NEW.opening_balance > 0 THEN
        -- Owner's Capital account
        SELECT account_id INTO cap_acc 
        FROM ChartOfAccounts 
        WHERE account_name = 'Owner''s Capital';

        IF cap_acc IS NULL THEN
            RAISE EXCEPTION 'Owner''s Capital account not found in COA';
        END IF;

        -- Create a new Journal Entry
        INSERT INTO JournalEntries(entry_date, description)
        VALUES (CURRENT_DATE, 'Opening Balance for ' || NEW.party_name)
        RETURNING journal_id INTO j_id;

        -- ---------------------------
        -- CUSTOMER or BOTH
        -- ---------------------------
        IF NEW.party_type IN ('Customer','Both') AND NEW.balance_type = 'Debit' THEN
            debit_acc := NEW.ar_account_id;
            credit_acc := cap_acc;

            INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
            VALUES (j_id, debit_acc, NEW.party_id, NEW.opening_balance);

            INSERT INTO JournalLines(journal_id, account_id, credit)
            VALUES (j_id, credit_acc, NEW.opening_balance);
        END IF;

        -- ---------------------------
        -- VENDOR or BOTH
        -- ---------------------------
        IF NEW.party_type IN ('Vendor','Both') AND NEW.balance_type = 'Credit' THEN
            debit_acc := cap_acc;
            credit_acc := NEW.ap_account_id;

            INSERT INTO JournalLines(journal_id, account_id, debit)
            VALUES (j_id, debit_acc, NEW.opening_balance);

            INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
            VALUES (j_id, credit_acc, NEW.party_id, NEW.opening_balance);
        END IF;

        -- ---------------------------
        -- EXPENSE PARTY
        -- ---------------------------
        IF NEW.party_type = 'Expense' THEN
            debit_acc := NEW.ap_account_id;  -- Expense account
            credit_acc := cap_acc;           -- Funded by Owner's Capital

            INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
            VALUES (j_id, debit_acc, NEW.party_id, NEW.opening_balance);

            INSERT INTO JournalLines(journal_id, account_id, credit)
            VALUES (j_id, credit_acc, NEW.opening_balance);
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.trg_party_opening_balance() OWNER TO postgres;

--
-- Name: trg_payment_journal(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trg_payment_journal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    party_acc BIGINT;
    v_party_name  TEXT;
    journal_desc TEXT;
BEGIN
    -- Handle DELETE: remove related journal
    IF TG_OP = 'DELETE' THEN
        DELETE FROM JournalEntries WHERE journal_id = OLD.journal_id;
        RETURN OLD;
    END IF;

    -- Handle UPDATE: only regenerate if relevant fields changed
    IF TG_OP = 'UPDATE' THEN
        IF OLD.amount = NEW.amount
           AND OLD.account_id = NEW.account_id
           AND OLD.party_id = NEW.party_id
           AND OLD.description IS NOT DISTINCT FROM NEW.description
           AND OLD.payment_date = NEW.payment_date THEN
            RETURN NEW;
        END IF;

        DELETE FROM JournalEntries WHERE journal_id = OLD.journal_id;
    END IF;

    -- Handle INSERT or UPDATE
    IF TG_OP IN ('INSERT','UPDATE') THEN
        -- Find AP account for vendor
        SELECT ap_account_id, p.party_name
        INTO party_acc, v_party_name
        FROM Parties AS p
        WHERE party_id = NEW.party_id;

        IF party_acc IS NULL THEN
            RAISE EXCEPTION 'No AP account found for vendor %', NEW.party_id;
        END IF;

        -- Description: custom if provided, else fallback with ref no
        journal_desc := COALESCE(
            NEW.description,
            'Payment to ' || v_party_name ||
            CASE WHEN NEW.reference_no IS NOT NULL AND NEW.reference_no <> '' 
                 THEN ' (Ref: ' || NEW.reference_no || ')'
                 ELSE '' END
        );

        -- Insert Journal Entry
        INSERT INTO JournalEntries(entry_date, description)
        VALUES (NEW.payment_date, journal_desc)
        RETURNING journal_id INTO j_id;

        -- Prevent recursion when linking back
        PERFORM pg_catalog.set_config('session_replication_role', 'replica', true);
        UPDATE Payments
        SET journal_id = j_id
        WHERE payment_id = NEW.payment_id;
        PERFORM pg_catalog.set_config('session_replication_role', 'origin', true);

        -- Debit Vendor (reduce liability)
        INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
        VALUES (j_id, party_acc, NEW.party_id, NEW.amount);

        -- Credit Cash/Bank
        INSERT INTO JournalLines(journal_id, account_id, credit)
        VALUES (j_id, NEW.account_id, NEW.amount);
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.trg_payment_journal() OWNER TO postgres;

--
-- Name: trg_receipt_journal(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trg_receipt_journal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    party_acc BIGINT;
    v_party_name  TEXT;
    journal_desc TEXT;
BEGIN
    -- Handle DELETE: remove related journal
    IF TG_OP = 'DELETE' THEN
        DELETE FROM JournalEntries WHERE journal_id = OLD.journal_id;
        RETURN OLD;
    END IF;

    -- Handle UPDATE: only regenerate if relevant fields changed
    IF TG_OP = 'UPDATE' THEN
        IF OLD.amount = NEW.amount
           AND OLD.account_id = NEW.account_id
           AND OLD.party_id = NEW.party_id
           AND OLD.description IS NOT DISTINCT FROM NEW.description
           AND OLD.receipt_date = NEW.receipt_date THEN
            RETURN NEW;
        END IF;

        DELETE FROM JournalEntries WHERE journal_id = OLD.journal_id;
    END IF;

    -- Handle INSERT or UPDATE
    IF TG_OP IN ('INSERT','UPDATE') THEN
        -- Find AR account for customer
        SELECT ar_account_id, p.party_name
        INTO party_acc, v_party_name
        FROM Parties AS p
        WHERE party_id = NEW.party_id;

        IF party_acc IS NULL THEN
            RAISE EXCEPTION 'No AR account found for customer %', NEW.party_id;
        END IF;

        -- Description: custom if provided, else fallback with ref no
        journal_desc := COALESCE(
            NEW.description,
            'Receipt from ' || v_party_name ||
            CASE WHEN NEW.reference_no IS NOT NULL AND NEW.reference_no <> '' 
                 THEN ' (Ref: ' || NEW.reference_no || ')'
                 ELSE '' END
        );

        -- Insert Journal Entry
        INSERT INTO JournalEntries(entry_date, description)
        VALUES (NEW.receipt_date, journal_desc)
        RETURNING journal_id INTO j_id;

        -- Prevent recursion when linking back
        PERFORM pg_catalog.set_config('session_replication_role', 'replica', true);
        UPDATE Receipts
        SET journal_id = j_id
        WHERE receipt_id = NEW.receipt_id;
        PERFORM pg_catalog.set_config('session_replication_role', 'origin', true);

        -- Debit Cash/Bank (increase asset)
        INSERT INTO JournalLines(journal_id, account_id, debit)
        VALUES (j_id, NEW.account_id, NEW.amount);

        -- Credit Customer (reduce receivable)
        INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
        VALUES (j_id, party_acc, NEW.party_id, NEW.amount);
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.trg_receipt_journal() OWNER TO postgres;

--
-- Name: update_item_from_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_item_from_json(item_data jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE Items
    SET
        item_name   = COALESCE(item_data->>'item_name', item_name),
        storage     = COALESCE(item_data->>'storage', storage),
        sale_price  = COALESCE(NULLIF(item_data->>'sale_price','')::NUMERIC, sale_price),
        item_code   = COALESCE(NULLIF(item_data->>'item_code',''), item_code),
        category    = COALESCE(NULLIF(item_data->>'category',''), category),
        brand       = COALESCE(NULLIF(item_data->>'brand',''), brand),
        updated_at  = NOW()
    WHERE item_id = (item_data->>'item_id')::BIGINT;
END;
$$;


ALTER FUNCTION public.update_item_from_json(item_data jsonb) OWNER TO postgres;

--
-- Name: update_party_from_json(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_party_from_json(p_id bigint, party_data jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    -- Old party data
    old_opening NUMERIC(14,2);
    old_balance_type VARCHAR(10);
    old_party_type VARCHAR(20);
    old_party_name VARCHAR(150);

    -- New values
    new_opening NUMERIC(14,2);
    new_balance_type VARCHAR(10);
    new_party_type VARCHAR(20);
    new_party_name VARCHAR(150);

    -- Accounting
    cap_acc BIGINT;
    j_id BIGINT;
    debit_acc BIGINT;
    credit_acc BIGINT;
    v_expense_account_id BIGINT;
BEGIN
    -- ============= FETCH EXISTING DATA =============
    SELECT opening_balance, balance_type, party_type, party_name
    INTO old_opening, old_balance_type, old_party_type, old_party_name
    FROM Parties
    WHERE party_id = p_id;

    -- ============= PARSE NEW VALUES =============
    new_opening := COALESCE((party_data->>'opening_balance')::NUMERIC, old_opening);
    new_balance_type := COALESCE(party_data->>'balance_type', old_balance_type);
    new_party_type := COALESCE(party_data->>'party_type', old_party_type);
    new_party_name := COALESCE(party_data->>'party_name', old_party_name);

    -- ============= EXPENSE PARTY LOGIC =============
    IF new_party_type = 'Expense' THEN
        -- Try to fetch the linked expense account (stored in ap_account_id)
        SELECT ap_account_id INTO v_expense_account_id
        FROM Parties WHERE party_id = p_id;

        -- If found, rename COA to match new name
        IF v_expense_account_id IS NOT NULL THEN
            UPDATE ChartOfAccounts
            SET account_name = new_party_name
            WHERE account_id = v_expense_account_id;
        ELSE
            -- Otherwise create a new Expense COA account
            INSERT INTO ChartOfAccounts (
                account_code, account_name, account_type, parent_account, date_created
            )
            VALUES (
                CONCAT('EXP-', LPAD((SELECT COUNT(*) + 1 FROM ChartOfAccounts WHERE account_type='Expense')::TEXT, 4, '0')),
                new_party_name,
                'Expense',
                (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Expenses' LIMIT 1),
                CURRENT_TIMESTAMP
            )
            RETURNING account_id INTO v_expense_account_id;
        END IF;
    END IF;

    -- ============= UPDATE PARTY DETAILS =============
    UPDATE Parties
    SET 
        party_name     = new_party_name,
        party_type     = new_party_type,
        contact_info   = COALESCE(party_data->>'contact_info', contact_info),
        address        = COALESCE(party_data->>'address', address),
        opening_balance = new_opening,
        balance_type   = new_balance_type,
        ar_account_id  = CASE 
                            WHEN new_party_type IN ('Customer','Both')
                            THEN (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Accounts Receivable' LIMIT 1)
                            ELSE NULL END,
        ap_account_id  = CASE 
                            WHEN new_party_type IN ('Vendor','Both')
                                THEN (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Accounts Payable' LIMIT 1)
                            WHEN new_party_type = 'Expense'
                                THEN v_expense_account_id
                            ELSE NULL 
                         END
    WHERE party_id = p_id;

    -- ============= SYNC JOURNAL DESCRIPTION IF PARTY NAME CHANGED =============
    IF new_party_name IS DISTINCT FROM old_party_name THEN
        UPDATE JournalEntries
        SET description = 'Opening Balance for ' || new_party_name
        WHERE journal_id IN (
            SELECT DISTINCT jl.journal_id
            FROM JournalLines jl
            WHERE jl.party_id = p_id
        )
        AND description ILIKE 'Opening Balance for%';
    END IF;

    -- ============= HANDLE OPENING BALANCE CHANGES =============
    IF new_opening IS DISTINCT FROM old_opening 
       OR new_balance_type IS DISTINCT FROM old_balance_type
       OR new_party_type IS DISTINCT FROM old_party_type THEN

        -- Delete old Opening Balance journals
        DELETE FROM JournalEntries je
        WHERE je.journal_id IN (
            SELECT jl.journal_id
            FROM JournalLines jl
            WHERE jl.party_id = p_id
        )
        AND je.description ILIKE 'Opening Balance for%';

        -- Get Owner's Capital account
        SELECT account_id INTO cap_acc 
        FROM ChartOfAccounts WHERE account_name = 'Owner''s Capital';

        IF cap_acc IS NULL THEN
            RAISE EXCEPTION 'Owner''s Capital account not found in COA';
        END IF;

        -- Recreate new Opening Balance entry
        INSERT INTO JournalEntries(entry_date, description)
        VALUES (CURRENT_DATE, 'Opening Balance for ' || new_party_name)
        RETURNING journal_id INTO j_id;

        -- Customer / Both (Debit balance)
        IF new_party_type IN ('Customer','Both') AND new_balance_type = 'Debit' AND new_opening > 0 THEN
            debit_acc := (SELECT ar_account_id FROM Parties WHERE party_id = p_id);
            credit_acc := cap_acc;

            INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
            VALUES (j_id, debit_acc, p_id, new_opening);

            INSERT INTO JournalLines(journal_id, account_id, credit)
            VALUES (j_id, credit_acc, new_opening);
        END IF;

        -- Vendor / Both (Credit balance)
        IF new_party_type IN ('Vendor','Both') AND new_balance_type = 'Credit' AND new_opening > 0 THEN
            debit_acc := cap_acc;
            credit_acc := (SELECT ap_account_id FROM Parties WHERE party_id = p_id);

            INSERT INTO JournalLines(journal_id, account_id, debit)
            VALUES (j_id, debit_acc, new_opening);

            INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
            VALUES (j_id, credit_acc, p_id, new_opening);
        END IF;
    END IF;
END;
$$;


ALTER FUNCTION public.update_party_from_json(p_id bigint, party_data jsonb) OWNER TO postgres;

--
-- Name: update_payment(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_payment(p_payment_id bigint, p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_amount    NUMERIC(14,2);
    v_method    TEXT;
    v_reference TEXT;
    v_desc      TEXT;
    v_date      DATE;
    v_party_id  BIGINT;
    v_updated   RECORD;
BEGIN
    v_amount    := NULLIF(p_data->>'amount','')::NUMERIC;
    v_method    := NULLIF(p_data->>'method','');
    v_reference := NULLIF(p_data->>'reference_no','');
    v_desc      := NULLIF(p_data->>'description','');
    v_date      := NULLIF(p_data->>'payment_date','')::DATE;

    IF p_data ? 'party_name' THEN
        SELECT party_id INTO v_party_id
        FROM Parties
        WHERE party_name = p_data->>'party_name'
        LIMIT 1;
        IF v_party_id IS NULL THEN
            RAISE EXCEPTION 'Vendor % not found', p_data->>'party_name';
        END IF;
    END IF;

    IF v_amount IS NOT NULL AND v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount';
    END IF;

    UPDATE Payments
    SET amount       = COALESCE(v_amount, amount),
        method       = COALESCE(v_method, method),
        reference_no = COALESCE(v_reference, reference_no),
        party_id     = COALESCE(v_party_id, party_id),
        description  = COALESCE(v_desc, description),
        payment_date = COALESCE(v_date, payment_date)
    WHERE payment_id = p_payment_id
    RETURNING * INTO v_updated;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Payment ID % not found', p_payment_id;
    END IF;

    RETURN jsonb_build_object(
        'status','success',
        'message','Payment updated successfully',
        'payment', to_jsonb(v_updated)
    );
END;
$$;


ALTER FUNCTION public.update_payment(p_payment_id bigint, p_data jsonb) OWNER TO postgres;

--
-- Name: update_purchase_invoice(bigint, jsonb, text, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_purchase_invoice(p_invoice_id bigint, p_items jsonb, p_party_name text DEFAULT NULL::text, p_invoice_date date DEFAULT NULL::date) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_item JSONB;
    v_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_purchase_item_id BIGINT;
    v_serial TEXT;
    v_new_party_id BIGINT;
BEGIN
    -- ========================================================
    -- 1️⃣ Update Party (Vendor) if given
    -- ========================================================
    IF p_party_name IS NOT NULL THEN
        SELECT party_id INTO v_new_party_id
        FROM Parties
        WHERE party_name = p_party_name
        LIMIT 1;

        IF v_new_party_id IS NULL THEN
            RAISE EXCEPTION 'Vendor "%" not found in Parties table.', p_party_name;
        END IF;

        UPDATE PurchaseInvoices
        SET vendor_id = v_new_party_id
        WHERE purchase_invoice_id = p_invoice_id;
    END IF;

    -- ========================================================
    -- 2️⃣ Update Invoice Date (if provided)
    -- ========================================================
    IF p_invoice_date IS NOT NULL THEN
        UPDATE PurchaseInvoices
        SET invoice_date = p_invoice_date
        WHERE purchase_invoice_id = p_invoice_id;
    END IF;

    -- ========================================================
    -- 3️⃣ Delete old items + stock movements
    -- ========================================================
    DELETE FROM StockMovements 
    WHERE reference_type = 'PurchaseInvoice' AND reference_id = p_invoice_id;

    DELETE FROM PurchaseUnits 
    WHERE purchase_item_id IN (
        SELECT purchase_item_id FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id
    );

    DELETE FROM PurchaseItems 
    WHERE purchase_invoice_id = p_invoice_id;

    -- ========================================================
    -- 4️⃣ Insert updated items and serials
    -- ========================================================
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Get or create item
        SELECT item_id INTO v_item_id FROM Items WHERE item_name = (v_item->>'item_name') LIMIT 1;
        IF v_item_id IS NULL THEN
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        -- Insert item
        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (
            p_invoice_id,
            v_item_id,
            (v_item->>'qty')::INT,
            (v_item->>'unit_price')::NUMERIC
        )
        RETURNING purchase_item_id INTO v_purchase_item_id;

        -- Accumulate total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Insert serials and stock movements
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            INSERT INTO PurchaseUnits(purchase_item_id, serial_number, in_stock)
            VALUES (v_purchase_item_id, v_serial, TRUE);

            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'IN', 'PurchaseInvoice', p_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- ========================================================
    -- 5️⃣ Update total in Purchase Invoice
    -- ========================================================
    UPDATE PurchaseInvoices
    SET total_amount = v_total
    WHERE purchase_invoice_id = p_invoice_id;

    -- ========================================================
    -- 6️⃣ Rebuild journal entry (refreshes vendor + date)
    -- ========================================================
    PERFORM rebuild_purchase_journal(p_invoice_id);

END;
$$;


ALTER FUNCTION public.update_purchase_invoice(p_invoice_id bigint, p_items jsonb, p_party_name text, p_invoice_date date) OWNER TO postgres;

--
-- Name: update_purchase_items(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_purchase_items(p_invoice_id bigint, p_items jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_item JSONB;
    v_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_purchase_item_id BIGINT;
    v_serial TEXT;
BEGIN
    -- Remove old stock + items
    DELETE FROM StockMovements WHERE reference_type = 'PurchaseInvoice' AND reference_id = p_invoice_id;
    DELETE FROM PurchaseUnits WHERE purchase_item_id IN (SELECT purchase_item_id FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id);
    DELETE FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id;

    -- Insert new items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Resolve or create item
        SELECT item_id INTO v_item_id FROM Items WHERE item_name = (v_item->>'item_name') LIMIT 1;
        IF v_item_id IS NULL THEN
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        -- Insert purchase item
        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (p_invoice_id, v_item_id, (v_item->>'qty')::INT, (v_item->>'unit_price')::NUMERIC)
        RETURNING purchase_item_id INTO v_purchase_item_id;

        -- Total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Units + Stock IN
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            INSERT INTO PurchaseUnits(purchase_item_id, serial_number, in_stock)
            VALUES (v_purchase_item_id, v_serial, TRUE);

            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'IN', 'PurchaseInvoice', p_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- Update invoice total
    UPDATE PurchaseInvoices SET total_amount = v_total WHERE purchase_invoice_id = p_invoice_id;

    -- 🔑 Rebuild journal manually
    PERFORM rebuild_purchase_journal(p_invoice_id);
END;
$$;


ALTER FUNCTION public.update_purchase_items(p_invoice_id bigint, p_items jsonb) OWNER TO postgres;

--
-- Name: update_purchase_items(bigint, jsonb, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_purchase_items(p_invoice_id bigint, p_items jsonb, p_party_name text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_item JSONB;
    v_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_purchase_item_id BIGINT;
    v_serial TEXT;
    v_new_party_id BIGINT;
BEGIN
    -- ✅ If a new party name is provided, update vendor
    IF p_party_name IS NOT NULL THEN
        SELECT party_id INTO v_new_party_id
        FROM Parties
        WHERE party_name = p_party_name
        LIMIT 1;

        IF v_new_party_id IS NULL THEN
            RAISE EXCEPTION 'Vendor "%" not found in Parties table.', p_party_name;
        END IF;

        UPDATE PurchaseInvoices
        SET vendor_id = v_new_party_id
        WHERE purchase_invoice_id = p_invoice_id;
    END IF;

    -- Remove old stock + items
    DELETE FROM StockMovements WHERE reference_type = 'PurchaseInvoice' AND reference_id = p_invoice_id;
    DELETE FROM PurchaseUnits WHERE purchase_item_id IN (SELECT purchase_item_id FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id);
    DELETE FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id;

    -- Insert new items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Resolve or create item
        SELECT item_id INTO v_item_id FROM Items WHERE item_name = (v_item->>'item_name') LIMIT 1;
        IF v_item_id IS NULL THEN
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        -- Insert purchase item
        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (p_invoice_id, v_item_id, (v_item->>'qty')::INT, (v_item->>'unit_price')::NUMERIC)
        RETURNING purchase_item_id INTO v_purchase_item_id;

        -- Total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Units + Stock IN
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            INSERT INTO PurchaseUnits(purchase_item_id, serial_number, in_stock)
            VALUES (v_purchase_item_id, v_serial, TRUE);

            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'IN', 'PurchaseInvoice', p_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- Update invoice total
    UPDATE PurchaseInvoices SET total_amount = v_total WHERE purchase_invoice_id = p_invoice_id;

    -- 🔑 Rebuild journal manually (to reflect new vendor)
    PERFORM rebuild_purchase_journal(p_invoice_id);
END;
$$;


ALTER FUNCTION public.update_purchase_items(p_invoice_id bigint, p_items jsonb, p_party_name text) OWNER TO postgres;

--
-- Name: update_purchase_return(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_purchase_return(p_return_id bigint, p_serials jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
    v_serial TEXT;
    v_unit RECORD;
    v_total NUMERIC(14,2) := 0;
    v_vendor_id BIGINT;
BEGIN
    -- 1. Get vendor id from return header
    SELECT vendor_id INTO v_vendor_id
    FROM PurchaseReturns
    WHERE purchase_return_id = p_return_id;

    IF v_vendor_id IS NULL THEN
        RAISE EXCEPTION 'Purchase Return % not found', p_return_id;
    END IF;

    -- 2. Reverse old items (restore stock)
    FOR rec IN
        SELECT serial_number, item_id
        FROM PurchaseReturnItems
        WHERE purchase_return_id = p_return_id
    LOOP
        UPDATE PurchaseUnits
        SET in_stock = TRUE
        WHERE serial_number = rec.serial_number;

        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'IN', 'PurchaseReturn-Update-Reverse', p_return_id, 1);
    END LOOP;

    -- 3. Remove old items
    DELETE FROM PurchaseReturnItems WHERE purchase_return_id = p_return_id;

    -- 4. Insert new items
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT pu.unit_id, pu.serial_number, pi.item_id, pi.unit_price, p.vendor_id
        INTO v_unit
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in PurchaseUnits', v_serial;
        END IF;

        -- check if in stock
        IF NOT EXISTS (
            SELECT 1 FROM PurchaseUnits WHERE unit_id = v_unit.unit_id AND in_stock = TRUE
        ) THEN
            RAISE EXCEPTION 'Serial % is not currently in stock', v_serial;
        END IF;

        -- check vendor match
        IF v_unit.vendor_id <> v_vendor_id THEN
            RAISE EXCEPTION 'Serial % was purchased from a different vendor', v_serial;
        END IF;

        -- mark as returned (out of stock)
        UPDATE PurchaseUnits 
        SET in_stock = FALSE 
        WHERE unit_id = v_unit.unit_id;

        -- log stock OUT
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'OUT', 'PurchaseReturn-Update', p_return_id, 1);

        -- insert return line (✅ unit_price instead of cost_price)
        INSERT INTO PurchaseReturnItems(purchase_return_id, item_id, unit_price, serial_number)
        VALUES (p_return_id, v_unit.item_id, v_unit.unit_price, v_serial);

        v_total := v_total + v_unit.unit_price;
    END LOOP;

    -- 5. Update header total
    UPDATE PurchaseReturns
    SET total_amount = v_total
    WHERE purchase_return_id = p_return_id;

    -- 6. Rebuild journal
    PERFORM rebuild_purchase_return_journal(p_return_id);
END;
$$;


ALTER FUNCTION public.update_purchase_return(p_return_id bigint, p_serials jsonb) OWNER TO postgres;

--
-- Name: update_receipt(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_receipt(p_receipt_id bigint, p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_amount    NUMERIC(14,2);
    v_method    TEXT;
    v_reference TEXT;
    v_desc      TEXT;
    v_date      DATE;
    v_party_id  BIGINT;
    v_updated   RECORD;
BEGIN
    v_amount    := NULLIF(p_data->>'amount','')::NUMERIC;
    v_method    := NULLIF(p_data->>'method','');
    v_reference := NULLIF(p_data->>'reference_no','');
    v_desc      := NULLIF(p_data->>'description','');
    v_date      := NULLIF(p_data->>'receipt_date','')::DATE;

    IF p_data ? 'party_name' THEN
        SELECT party_id INTO v_party_id
        FROM Parties
        WHERE party_name = p_data->>'party_name'
        LIMIT 1;
        IF v_party_id IS NULL THEN
            RAISE EXCEPTION 'Customer % not found', p_data->>'party_name';
        END IF;
    END IF;

    IF v_amount IS NOT NULL AND v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount';
    END IF;

    UPDATE Receipts
    SET amount       = COALESCE(v_amount, amount),
        method       = COALESCE(v_method, method),
        reference_no = COALESCE(v_reference, reference_no),
        party_id     = COALESCE(v_party_id, party_id),
        description  = COALESCE(v_desc, description),
        receipt_date = COALESCE(v_date, receipt_date)
    WHERE receipt_id = p_receipt_id
    RETURNING * INTO v_updated;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receipt ID % not found', p_receipt_id;
    END IF;

    RETURN jsonb_build_object(
        'status','success',
        'message','Receipt updated successfully',
        'receipt', to_jsonb(v_updated)
    );
END;
$$;


ALTER FUNCTION public.update_receipt(p_receipt_id bigint, p_data jsonb) OWNER TO postgres;

--
-- Name: update_sale_invoice(bigint, jsonb, text, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_sale_invoice(p_invoice_id bigint, p_items jsonb, p_party_name text DEFAULT NULL::text, p_invoice_date date DEFAULT NULL::date) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_item JSONB;
    v_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_sales_item_id BIGINT;
    v_serial TEXT;
    v_unit_id BIGINT;
    v_new_party_id BIGINT;
BEGIN
    -- ========================================================
    -- 1️⃣ Update Party (Customer) if given
    -- ========================================================
    IF p_party_name IS NOT NULL THEN
        SELECT party_id INTO v_new_party_id
        FROM Parties
        WHERE party_name = p_party_name
        LIMIT 1;

        IF v_new_party_id IS NULL THEN
            RAISE EXCEPTION 'Customer "%" not found in Parties table.', p_party_name;
        END IF;

        UPDATE SalesInvoices
        SET customer_id = v_new_party_id
        WHERE sales_invoice_id = p_invoice_id;
    END IF;

    -- ========================================================
    -- 2️⃣ Update Invoice Date (if provided)
    -- ========================================================
    IF p_invoice_date IS NOT NULL THEN
        UPDATE SalesInvoices
        SET invoice_date = p_invoice_date
        WHERE sales_invoice_id = p_invoice_id;
    END IF;

    -- ========================================================
    -- 3️⃣ Delete old items + sold units + stock movements
    -- ========================================================
    DELETE FROM StockMovements 
    WHERE reference_type = 'SalesInvoice' AND reference_id = p_invoice_id;

    DELETE FROM SoldUnits
    WHERE sales_item_id IN (
        SELECT sales_item_id FROM SalesItems WHERE sales_invoice_id = p_invoice_id
    );

    DELETE FROM SalesItems 
    WHERE sales_invoice_id = p_invoice_id;

    -- ========================================================
    -- 4️⃣ Insert new/updated items and serials
    -- ========================================================
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Find item_id
        SELECT item_id INTO v_item_id
        FROM Items
        WHERE item_name = (v_item->>'item_name')
        LIMIT 1;

        IF v_item_id IS NULL THEN
            RAISE EXCEPTION 'Item "%" not found in Items table for update_sale_invoice', (v_item->>'item_name');
        END IF;

        -- Insert sales item
        INSERT INTO SalesItems(sales_invoice_id, item_id, quantity, unit_price)
        VALUES (
            p_invoice_id,
            v_item_id,
            (v_item->>'qty')::INT,
            (v_item->>'unit_price')::NUMERIC
        )
        RETURNING sales_item_id INTO v_sales_item_id;

        -- Add to total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Insert sold units + stock movements
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            -- get matching purchase unit
            SELECT unit_id INTO v_unit_id
            FROM PurchaseUnits
            WHERE serial_number = v_serial
            LIMIT 1;

            IF v_unit_id IS NULL THEN
                RAISE EXCEPTION 'Serial % not found in PurchaseUnits', v_serial;
            END IF;

            -- mark unit as sold (in_stock = FALSE)
            UPDATE PurchaseUnits
            SET in_stock = FALSE
            WHERE unit_id = v_unit_id;

            -- insert into SoldUnits
            INSERT INTO SoldUnits(sales_item_id, unit_id, sold_price, status)
            VALUES (v_sales_item_id, v_unit_id, (v_item->>'unit_price')::NUMERIC, 'Sold');

            -- log stock OUT
            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'OUT', 'SalesInvoice', p_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- ========================================================
    -- 5️⃣ Update total amount
    -- ========================================================
    UPDATE SalesInvoices
    SET total_amount = v_total
    WHERE sales_invoice_id = p_invoice_id;

    -- ========================================================
    -- 6️⃣ Rebuild journal (refreshes AR, Revenue, COGS, Inventory)
    -- ========================================================
    PERFORM rebuild_sales_journal(p_invoice_id);

END;
$$;


ALTER FUNCTION public.update_sale_invoice(p_invoice_id bigint, p_items jsonb, p_party_name text, p_invoice_date date) OWNER TO postgres;

--
-- Name: update_sale_return(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_sale_return(p_return_id bigint, p_serials jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
    v_serial TEXT;
    v_unit RECORD;
    v_total NUMERIC(14,2) := 0;
    v_cost NUMERIC(14,2) := 0;
    v_customer_id BIGINT;
BEGIN
    -- 1. Reverse old items
    FOR rec IN
        SELECT serial_number, item_id
        FROM SalesReturnItems
        WHERE sales_return_id = p_return_id
    LOOP
        -- revert SoldUnits status
        UPDATE SoldUnits
        SET status = 'Sold'
        WHERE unit_id = (
            SELECT unit_id FROM PurchaseUnits WHERE serial_number = rec.serial_number LIMIT 1
        );

        -- remove stock
        UPDATE PurchaseUnits
        SET in_stock = FALSE
        WHERE serial_number = rec.serial_number;

        -- log OUT
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'OUT', 'SalesReturn-Update-Reverse', p_return_id, 1);
    END LOOP;

    -- 2. Remove old items
    DELETE FROM SalesReturnItems WHERE sales_return_id = p_return_id;

    -- 3. Get customer id
    SELECT customer_id INTO v_customer_id
    FROM SalesReturns
    WHERE sales_return_id = p_return_id;

    -- 4. Insert new items
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT su.sold_unit_id, su.unit_id, su.sold_price, si.item_id,
               si.sales_invoice_id, pu.serial_number, pi.unit_price, s.customer_id
        INTO v_unit
        FROM SoldUnits su
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in SoldUnits', v_serial;
        END IF;

        IF v_unit.customer_id <> v_customer_id THEN
            RAISE EXCEPTION 'Serial % was not sold to this customer', v_serial;
        END IF;

        UPDATE SoldUnits SET status = 'Returned' WHERE sold_unit_id = v_unit.sold_unit_id;
        UPDATE PurchaseUnits SET in_stock = TRUE WHERE unit_id = v_unit.unit_id;

        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'IN', 'SalesReturn-Update', p_return_id, 1);

        INSERT INTO SalesReturnItems(sales_return_id, item_id, sold_price, cost_price, serial_number)
        VALUES (p_return_id, v_unit.item_id, v_unit.sold_price, v_unit.unit_price, v_serial);

        v_total := v_total + v_unit.sold_price;
        v_cost := v_cost + v_unit.unit_price;
    END LOOP;

    -- 5. Update header total
    UPDATE SalesReturns
    SET total_amount = v_total
    WHERE sales_return_id = p_return_id;

	-- 6. Rebuild journal
    PERFORM rebuild_sales_return_journal(p_return_id);
END;
$$;


ALTER FUNCTION public.update_sale_return(p_return_id bigint, p_serials jsonb) OWNER TO postgres;

--
-- Name: validate_purchase_delete(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.validate_purchase_delete(p_invoice_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_invoice_serials TEXT[];
    v_sold_serials TEXT[];
    v_returned_serials TEXT[];
    v_message TEXT;
BEGIN
    -- 1️⃣ Get all serial numbers from this purchase invoice
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_invoice_serials
    FROM PurchaseUnits pu
    JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
    WHERE pi.purchase_invoice_id = p_invoice_id;

    IF v_invoice_serials IS NULL THEN
        v_invoice_serials := ARRAY[]::TEXT[];
    END IF;

    -- 2️⃣ Check if any of these serials are sold
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_sold_serials
    FROM SoldUnits su
    JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
    WHERE pu.serial_number = ANY(v_invoice_serials);

    IF v_sold_serials IS NULL THEN
        v_sold_serials := ARRAY[]::TEXT[];
    END IF;

    -- 3️⃣ Check if any of these serials are already returned to vendor
    SELECT ARRAY_AGG(pri.serial_number)
    INTO v_returned_serials
    FROM PurchaseReturnItems pri
    WHERE pri.serial_number = ANY(v_invoice_serials);

    IF v_returned_serials IS NULL THEN
        v_returned_serials := ARRAY[]::TEXT[];
    END IF;

    -- 4️⃣ If any sold or returned serials exist, prevent deletion
    IF array_length(v_sold_serials, 1) IS NOT NULL
       OR array_length(v_returned_serials, 1) IS NOT NULL THEN

        v_message := '❌ Purchase Invoice ' || p_invoice_id || ' cannot be deleted.';

        IF array_length(v_sold_serials, 1) IS NOT NULL THEN
            v_message := v_message || ' ' || array_length(v_sold_serials, 1) || ' sold serial(s) found.';
        END IF;

        IF array_length(v_returned_serials, 1) IS NOT NULL THEN
            v_message := v_message || ' ' || array_length(v_returned_serials, 1) || ' returned serial(s) found.';
        END IF;

        RETURN jsonb_build_object(
            'is_valid', FALSE,
            'message', v_message,
            'sold_serials', v_sold_serials,
            'returned_serials', v_returned_serials
        );
    END IF;

    -- 5️⃣ Otherwise, safe to delete
    RETURN jsonb_build_object(
        'is_valid', TRUE,
        'message', '✅ Safe to delete — no sold or returned serials found in this invoice.',
        'sold_serials', v_sold_serials,
        'returned_serials', v_returned_serials
    );
END;
$$;


ALTER FUNCTION public.validate_purchase_delete(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: validate_purchase_update(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.validate_purchase_update(p_invoice_id bigint, p_items jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_existing_serials TEXT[];
    v_new_serials TEXT[];
    v_removed_serials TEXT[];
    v_sold_serials TEXT[];
    v_returned_serials TEXT[];
    v_message TEXT;
BEGIN
    -- 1️⃣ Get all serials currently in this purchase invoice
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_existing_serials
    FROM PurchaseUnits pu
    JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
    WHERE pi.purchase_invoice_id = p_invoice_id;

    IF v_existing_serials IS NULL THEN
        v_existing_serials := ARRAY[]::TEXT[];
    END IF;

    -- 2️⃣ Extract all serials from the new JSON data (flatten correctly)
    SELECT ARRAY_AGG(serial::TEXT)
    INTO v_new_serials
    FROM jsonb_array_elements(p_items) AS item,
         jsonb_array_elements_text(item->'serials') AS serial;

    IF v_new_serials IS NULL THEN
        v_new_serials := ARRAY[]::TEXT[];
    END IF;

    -- 3️⃣ Find removed serials (those that existed before but not now)
    SELECT ARRAY_AGG(s)
    INTO v_removed_serials
    FROM unnest(v_existing_serials) AS s
    WHERE s <> ALL(v_new_serials);

    IF v_removed_serials IS NULL THEN
        v_removed_serials := ARRAY[]::TEXT[];
    END IF;

    -- 4️⃣ Check if removed serials are sold
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_sold_serials
    FROM SoldUnits su
    JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
    WHERE pu.serial_number = ANY(v_removed_serials);

    IF v_sold_serials IS NULL THEN
        v_sold_serials := ARRAY[]::TEXT[];
    END IF;

    -- 5️⃣ Check if removed serials are already returned to vendor
    SELECT ARRAY_AGG(pri.serial_number)
    INTO v_returned_serials
    FROM PurchaseReturnItems pri
    WHERE pri.serial_number = ANY(v_removed_serials);

    IF v_returned_serials IS NULL THEN
        v_returned_serials := ARRAY[]::TEXT[];
    END IF;

    -- 6️⃣ If any conflicts found, return descriptive message
    IF array_length(v_sold_serials, 1) IS NOT NULL
       OR array_length(v_returned_serials, 1) IS NOT NULL THEN

        v_message := '❌ Some serials cannot be removed.';

        IF array_length(v_sold_serials, 1) IS NOT NULL THEN
            v_message := v_message || ' ' || array_length(v_sold_serials, 1) || ' sold serial(s) found.';
        END IF;

        IF array_length(v_returned_serials, 1) IS NOT NULL THEN
            v_message := v_message || ' ' || array_length(v_returned_serials, 1) || ' returned serial(s) found.';
        END IF;

        RETURN jsonb_build_object(
            'is_valid', FALSE,
            'message', v_message,
            'sold_serials', v_sold_serials,
            'returned_serials', v_returned_serials
        );
    END IF;

    -- 7️⃣ Otherwise, all safe
    RETURN jsonb_build_object(
        'is_valid', TRUE,
        'message', '✅ Safe to update — no sold or returned serials will be removed.',
        'sold_serials', v_sold_serials,
        'returned_serials', v_returned_serials
    );
END;
$$;


ALTER FUNCTION public.validate_purchase_update(p_invoice_id bigint, p_items jsonb) OWNER TO postgres;

--
-- Name: validate_sales_delete(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.validate_sales_delete(p_invoice_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_invoice_serials TEXT[];
    v_returned_serials TEXT[];
    v_message TEXT;
BEGIN
    -- 1️⃣ Get all serials belonging to this Sales Invoice
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_invoice_serials
    FROM SoldUnits su
    JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
    JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
    WHERE si.sales_invoice_id = p_invoice_id;

    IF v_invoice_serials IS NULL THEN
        v_invoice_serials := ARRAY[]::TEXT[];
    END IF;

    -- 2️⃣ Check which of these serials are already returned
    SELECT ARRAY_AGG(sri.serial_number)
    INTO v_returned_serials
    FROM SalesReturnItems sri
    WHERE sri.serial_number = ANY(v_invoice_serials);

    IF v_returned_serials IS NULL THEN
        v_returned_serials := ARRAY[]::TEXT[];
    END IF;

    -- 3️⃣ If any serials are returned, block deletion
    IF array_length(v_returned_serials, 1) IS NOT NULL THEN
        v_message := '❌ Cannot delete Sales Invoice ' || p_invoice_id ||
                     ' — ' || array_length(v_returned_serials, 1) ||
                     ' serial(s) already returned.';

        RETURN jsonb_build_object(
            'is_valid', FALSE,
            'message', v_message,
            'returned_serials', v_returned_serials
        );
    END IF;

    -- 4️⃣ Otherwise, safe to delete
    RETURN jsonb_build_object(
        'is_valid', TRUE,
        'message', '✅ Safe to delete — no returned serials found.',
        'returned_serials', v_returned_serials
    );
END;
$$;


ALTER FUNCTION public.validate_sales_delete(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: validate_sales_update(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.validate_sales_update(p_invoice_id bigint, p_items jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_existing_serials TEXT[];
    v_new_serials TEXT[];
    v_removed_serials TEXT[];
    v_returned_serials TEXT[];
    v_message TEXT;
BEGIN
    -- 1️⃣ Get all serials currently in this sales invoice
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_existing_serials
    FROM SoldUnits su
    JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
    JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
    WHERE si.sales_invoice_id = p_invoice_id;

    IF v_existing_serials IS NULL THEN
        v_existing_serials := ARRAY[]::TEXT[];
    END IF;

    -- 2️⃣ Extract all serials from the new JSON data (flatten correctly)
    SELECT ARRAY_AGG(serial::TEXT)
    INTO v_new_serials
    FROM jsonb_array_elements(p_items) AS item,
         jsonb_array_elements_text(item->'serials') AS serial;

    IF v_new_serials IS NULL THEN
        v_new_serials := ARRAY[]::TEXT[];
    END IF;

    -- 3️⃣ Find removed serials (those that existed before but not now)
    SELECT ARRAY_AGG(s)
    INTO v_removed_serials
    FROM unnest(v_existing_serials) AS s
    WHERE s <> ALL(v_new_serials);

    IF v_removed_serials IS NULL THEN
        v_removed_serials := ARRAY[]::TEXT[];
    END IF;

    -- 4️⃣ Check if removed serials are already in Sales Return
    SELECT ARRAY_AGG(sri.serial_number)
    INTO v_returned_serials
    FROM SalesReturnItems sri
    WHERE sri.serial_number = ANY(v_removed_serials);

    IF v_returned_serials IS NULL THEN
        v_returned_serials := ARRAY[]::TEXT[];
    END IF;

    -- 5️⃣ If any conflicts found, return descriptive message
    IF array_length(v_returned_serials, 1) IS NOT NULL THEN
        v_message := '❌ Some serials cannot be removed. ' ||
                     array_length(v_returned_serials, 1) || ' serial(s) already returned.';

        RETURN jsonb_build_object(
            'is_valid', FALSE,
            'message', v_message,
            'returned_serials', v_returned_serials
        );
    END IF;

    -- 6️⃣ Otherwise, all safe
    RETURN jsonb_build_object(
        'is_valid', TRUE,
        'message', '✅ Safe to update — no returned serials will be removed.',
        'returned_serials', v_returned_serials
    );
END;
$$;


ALTER FUNCTION public.validate_sales_update(p_invoice_id bigint, p_items jsonb) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: auth_group; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_group (
    id integer NOT NULL,
    name character varying(150) NOT NULL
);


ALTER TABLE public.auth_group OWNER TO postgres;

--
-- Name: auth_group_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_group ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_group_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_group_permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_group_permissions (
    id bigint NOT NULL,
    group_id integer NOT NULL,
    permission_id integer NOT NULL
);


ALTER TABLE public.auth_group_permissions OWNER TO postgres;

--
-- Name: auth_group_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_group_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_group_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_permission; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_permission (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    content_type_id integer NOT NULL,
    codename character varying(100) NOT NULL
);


ALTER TABLE public.auth_permission OWNER TO postgres;

--
-- Name: auth_permission_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_permission ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_permission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_user; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_user (
    id integer NOT NULL,
    password character varying(128) NOT NULL,
    last_login timestamp with time zone,
    is_superuser boolean NOT NULL,
    username character varying(150) NOT NULL,
    first_name character varying(150) NOT NULL,
    last_name character varying(150) NOT NULL,
    email character varying(254) NOT NULL,
    is_staff boolean NOT NULL,
    is_active boolean NOT NULL,
    date_joined timestamp with time zone NOT NULL
);


ALTER TABLE public.auth_user OWNER TO postgres;

--
-- Name: auth_user_groups; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_user_groups (
    id bigint NOT NULL,
    user_id integer NOT NULL,
    group_id integer NOT NULL
);


ALTER TABLE public.auth_user_groups OWNER TO postgres;

--
-- Name: auth_user_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_user_groups ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_user_groups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_user_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_user ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_user_user_permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_user_user_permissions (
    id bigint NOT NULL,
    user_id integer NOT NULL,
    permission_id integer NOT NULL
);


ALTER TABLE public.auth_user_user_permissions OWNER TO postgres;

--
-- Name: auth_user_user_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_user_user_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_user_user_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: chartofaccounts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.chartofaccounts (
    account_id bigint NOT NULL,
    account_code character varying(20) NOT NULL,
    account_name character varying(150) NOT NULL,
    account_type character varying(20) NOT NULL,
    parent_account bigint,
    date_created timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chartofaccounts_account_type_check CHECK (((account_type)::text = ANY (ARRAY[('Asset'::character varying)::text, ('Liability'::character varying)::text, ('Equity'::character varying)::text, ('Revenue'::character varying)::text, ('Expense'::character varying)::text])))
);


ALTER TABLE public.chartofaccounts OWNER TO postgres;

--
-- Name: chartofaccounts_account_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.chartofaccounts_account_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.chartofaccounts_account_id_seq OWNER TO postgres;

--
-- Name: chartofaccounts_account_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.chartofaccounts_account_id_seq OWNED BY public.chartofaccounts.account_id;


--
-- Name: django_admin_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.django_admin_log (
    id integer NOT NULL,
    action_time timestamp with time zone NOT NULL,
    object_id text,
    object_repr character varying(200) NOT NULL,
    action_flag smallint NOT NULL,
    change_message text NOT NULL,
    content_type_id integer,
    user_id integer NOT NULL,
    CONSTRAINT django_admin_log_action_flag_check CHECK ((action_flag >= 0))
);


ALTER TABLE public.django_admin_log OWNER TO postgres;

--
-- Name: django_admin_log_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.django_admin_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_admin_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_content_type; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.django_content_type (
    id integer NOT NULL,
    app_label character varying(100) NOT NULL,
    model character varying(100) NOT NULL
);


ALTER TABLE public.django_content_type OWNER TO postgres;

--
-- Name: django_content_type_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.django_content_type ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_content_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_migrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.django_migrations (
    id bigint NOT NULL,
    app character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    applied timestamp with time zone NOT NULL
);


ALTER TABLE public.django_migrations OWNER TO postgres;

--
-- Name: django_migrations_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.django_migrations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_migrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_session; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.django_session (
    session_key character varying(40) NOT NULL,
    session_data text NOT NULL,
    expire_date timestamp with time zone NOT NULL
);


ALTER TABLE public.django_session OWNER TO postgres;

--
-- Name: journalentries; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.journalentries (
    journal_id bigint NOT NULL,
    entry_date date DEFAULT CURRENT_DATE NOT NULL,
    description text,
    date_created timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.journalentries OWNER TO postgres;

--
-- Name: journallines; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.journallines (
    line_id bigint NOT NULL,
    journal_id bigint NOT NULL,
    account_id bigint NOT NULL,
    party_id bigint,
    debit numeric(14,2) DEFAULT 0,
    credit numeric(14,2) DEFAULT 0,
    CONSTRAINT journallines_check CHECK (((debit >= (0)::numeric) AND (credit >= (0)::numeric))),
    CONSTRAINT journallines_check1 CHECK ((NOT ((debit = (0)::numeric) AND (credit = (0)::numeric))))
);


ALTER TABLE public.journallines OWNER TO postgres;

--
-- Name: generalledger; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.generalledger AS
 SELECT jl.line_id AS gl_entry_id,
    je.journal_id,
    je.entry_date,
    jl.account_id,
    jl.party_id,
    jl.debit,
    jl.credit,
    je.description
   FROM (public.journallines jl
     JOIN public.journalentries je ON ((jl.journal_id = je.journal_id)));


ALTER VIEW public.generalledger OWNER TO postgres;

--
-- Name: items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.items (
    item_id bigint NOT NULL,
    item_name character varying(150) NOT NULL,
    storage character varying(100),
    sale_price numeric(12,2) DEFAULT 0.00 NOT NULL,
    item_code character varying(50),
    category character varying(100),
    brand character varying(100),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.items OWNER TO postgres;

--
-- Name: parties; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.parties (
    party_id bigint NOT NULL,
    party_name character varying(150) NOT NULL,
    party_type character varying(20) NOT NULL,
    contact_info character varying(50),
    address text,
    ar_account_id bigint,
    ap_account_id bigint,
    opening_balance numeric(14,2) DEFAULT 0,
    balance_type character varying(10) DEFAULT 'Debit'::character varying,
    date_created timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT parties_balance_type_check CHECK (((balance_type)::text = ANY (ARRAY[('Debit'::character varying)::text, ('Credit'::character varying)::text]))),
    CONSTRAINT parties_party_type_check CHECK (((party_type)::text = ANY (ARRAY[('Customer'::character varying)::text, ('Vendor'::character varying)::text, ('Both'::character varying)::text, ('Expense'::character varying)::text])))
);


ALTER TABLE public.parties OWNER TO postgres;

--
-- Name: purchaseinvoices; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchaseinvoices (
    purchase_invoice_id bigint NOT NULL,
    vendor_id bigint NOT NULL,
    invoice_date date DEFAULT CURRENT_DATE NOT NULL,
    total_amount numeric(14,2) NOT NULL,
    journal_id bigint
);


ALTER TABLE public.purchaseinvoices OWNER TO postgres;

--
-- Name: purchaseitems; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchaseitems (
    purchase_item_id bigint NOT NULL,
    purchase_invoice_id bigint NOT NULL,
    item_id bigint NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(12,2) NOT NULL,
    CONSTRAINT purchaseitems_quantity_check CHECK ((quantity > 0))
);


ALTER TABLE public.purchaseitems OWNER TO postgres;

--
-- Name: purchaseunits; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchaseunits (
    unit_id bigint NOT NULL,
    purchase_item_id bigint NOT NULL,
    serial_number character varying(100) NOT NULL,
    in_stock boolean DEFAULT true
);


ALTER TABLE public.purchaseunits OWNER TO postgres;

--
-- Name: salesinvoices; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.salesinvoices (
    sales_invoice_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    invoice_date date DEFAULT CURRENT_DATE NOT NULL,
    total_amount numeric(14,2) NOT NULL,
    journal_id bigint
);


ALTER TABLE public.salesinvoices OWNER TO postgres;

--
-- Name: salesitems; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.salesitems (
    sales_item_id bigint NOT NULL,
    sales_invoice_id bigint NOT NULL,
    item_id bigint NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(12,2) NOT NULL,
    CONSTRAINT salesitems_quantity_check CHECK ((quantity > 0))
);


ALTER TABLE public.salesitems OWNER TO postgres;

--
-- Name: soldunits; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.soldunits (
    sold_unit_id bigint NOT NULL,
    sales_item_id bigint NOT NULL,
    unit_id bigint NOT NULL,
    sold_price numeric(12,2) NOT NULL,
    status character varying(20) DEFAULT 'Sold'::character varying,
    CONSTRAINT soldunits_status_check CHECK (((status)::text = ANY (ARRAY[('Sold'::character varying)::text, ('Returned'::character varying)::text, ('Damaged'::character varying)::text])))
);


ALTER TABLE public.soldunits OWNER TO postgres;

--
-- Name: item_history_view; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.item_history_view AS
 WITH purchase_history AS (
         SELECT i.item_id,
            i.item_name,
            pu.serial_number,
            p.invoice_date AS transaction_date,
            'PURCHASE'::text AS transaction_type,
            v.party_name AS counterparty,
            pi.unit_price AS price
           FROM ((((public.purchaseunits pu
             JOIN public.purchaseitems pi ON ((pu.purchase_item_id = pi.purchase_item_id)))
             JOIN public.purchaseinvoices p ON ((pi.purchase_invoice_id = p.purchase_invoice_id)))
             JOIN public.items i ON ((pi.item_id = i.item_id)))
             JOIN public.parties v ON ((p.vendor_id = v.party_id)))
          WHERE ((i.item_name)::text ~~* '%iPhone 15 Pro%'::text)
        ), sale_history AS (
         SELECT i.item_id,
            i.item_name,
            pu.serial_number,
            s.invoice_date AS transaction_date,
            'SALE'::text AS transaction_type,
            c.party_name AS counterparty,
            su.sold_price AS price
           FROM (((((public.soldunits su
             JOIN public.purchaseunits pu ON ((su.unit_id = pu.unit_id)))
             JOIN public.salesitems si ON ((su.sales_item_id = si.sales_item_id)))
             JOIN public.salesinvoices s ON ((si.sales_invoice_id = s.sales_invoice_id)))
             JOIN public.items i ON ((si.item_id = i.item_id)))
             JOIN public.parties c ON ((s.customer_id = c.party_id)))
          WHERE ((i.item_name)::text ~~* '%iPhone 15 Pro%'::text)
        )
 SELECT item_name,
    serial_number,
    transaction_date,
    transaction_type,
    counterparty,
    price
   FROM ( SELECT purchase_history.item_id,
            purchase_history.item_name,
            purchase_history.serial_number,
            purchase_history.transaction_date,
            purchase_history.transaction_type,
            purchase_history.counterparty,
            purchase_history.price
           FROM purchase_history
        UNION ALL
         SELECT sale_history.item_id,
            sale_history.item_name,
            sale_history.serial_number,
            sale_history.transaction_date,
            sale_history.transaction_type,
            sale_history.counterparty,
            sale_history.price
           FROM sale_history) combined
  ORDER BY transaction_date, transaction_type DESC, serial_number;


ALTER VIEW public.item_history_view OWNER TO postgres;

--
-- Name: items_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.items_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.items_item_id_seq OWNER TO postgres;

--
-- Name: items_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.items_item_id_seq OWNED BY public.items.item_id;


--
-- Name: journalentries_journal_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.journalentries_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.journalentries_journal_id_seq OWNER TO postgres;

--
-- Name: journalentries_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.journalentries_journal_id_seq OWNED BY public.journalentries.journal_id;


--
-- Name: journallines_line_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.journallines_line_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.journallines_line_id_seq OWNER TO postgres;

--
-- Name: journallines_line_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.journallines_line_id_seq OWNED BY public.journallines.line_id;


--
-- Name: parties_party_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.parties_party_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.parties_party_id_seq OWNER TO postgres;

--
-- Name: parties_party_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.parties_party_id_seq OWNED BY public.parties.party_id;


--
-- Name: payments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payments (
    payment_id bigint NOT NULL,
    party_id bigint NOT NULL,
    account_id bigint NOT NULL,
    amount numeric(14,2) NOT NULL,
    payment_date date DEFAULT CURRENT_DATE NOT NULL,
    method character varying(20),
    reference_no character varying(100),
    journal_id bigint,
    date_created timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    notes text,
    description text,
    CONSTRAINT payments_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT payments_method_check CHECK (((method)::text = ANY (ARRAY[('Cash'::character varying)::text, ('Bank'::character varying)::text, ('Cheque'::character varying)::text, ('Online'::character varying)::text])))
);


ALTER TABLE public.payments OWNER TO postgres;

--
-- Name: payments_payment_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.payments_payment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.payments_payment_id_seq OWNER TO postgres;

--
-- Name: payments_payment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.payments_payment_id_seq OWNED BY public.payments.payment_id;


--
-- Name: payments_ref_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.payments_ref_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.payments_ref_seq OWNER TO postgres;

--
-- Name: purchaseinvoices_purchase_invoice_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchaseinvoices_purchase_invoice_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchaseinvoices_purchase_invoice_id_seq OWNER TO postgres;

--
-- Name: purchaseinvoices_purchase_invoice_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchaseinvoices_purchase_invoice_id_seq OWNED BY public.purchaseinvoices.purchase_invoice_id;


--
-- Name: purchaseitems_purchase_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchaseitems_purchase_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchaseitems_purchase_item_id_seq OWNER TO postgres;

--
-- Name: purchaseitems_purchase_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchaseitems_purchase_item_id_seq OWNED BY public.purchaseitems.purchase_item_id;


--
-- Name: purchasereturnitems; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchasereturnitems (
    return_item_id bigint NOT NULL,
    purchase_return_id bigint NOT NULL,
    item_id bigint NOT NULL,
    unit_price numeric(12,2) NOT NULL,
    serial_number character varying(100) NOT NULL
);


ALTER TABLE public.purchasereturnitems OWNER TO postgres;

--
-- Name: purchasereturnitems_return_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchasereturnitems_return_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchasereturnitems_return_item_id_seq OWNER TO postgres;

--
-- Name: purchasereturnitems_return_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchasereturnitems_return_item_id_seq OWNED BY public.purchasereturnitems.return_item_id;


--
-- Name: purchasereturns; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchasereturns (
    purchase_return_id bigint NOT NULL,
    vendor_id bigint NOT NULL,
    return_date date DEFAULT CURRENT_DATE NOT NULL,
    total_amount numeric(14,2) DEFAULT 0 NOT NULL,
    journal_id bigint
);


ALTER TABLE public.purchasereturns OWNER TO postgres;

--
-- Name: purchasereturns_purchase_return_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchasereturns_purchase_return_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchasereturns_purchase_return_id_seq OWNER TO postgres;

--
-- Name: purchasereturns_purchase_return_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchasereturns_purchase_return_id_seq OWNED BY public.purchasereturns.purchase_return_id;


--
-- Name: purchaseunits_unit_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchaseunits_unit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchaseunits_unit_id_seq OWNER TO postgres;

--
-- Name: purchaseunits_unit_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchaseunits_unit_id_seq OWNED BY public.purchaseunits.unit_id;


--
-- Name: receipts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.receipts (
    receipt_id bigint NOT NULL,
    party_id bigint NOT NULL,
    account_id bigint NOT NULL,
    amount numeric(14,2) NOT NULL,
    receipt_date date DEFAULT CURRENT_DATE NOT NULL,
    method character varying(20),
    reference_no character varying(100),
    journal_id bigint,
    date_created timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    notes text,
    description text,
    CONSTRAINT receipts_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT receipts_method_check CHECK (((method)::text = ANY (ARRAY[('Cash'::character varying)::text, ('Bank'::character varying)::text, ('Cheque'::character varying)::text, ('Online'::character varying)::text])))
);


ALTER TABLE public.receipts OWNER TO postgres;

--
-- Name: receipts_receipt_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.receipts_receipt_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.receipts_receipt_id_seq OWNER TO postgres;

--
-- Name: receipts_receipt_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.receipts_receipt_id_seq OWNED BY public.receipts.receipt_id;


--
-- Name: receipts_ref_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.receipts_ref_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.receipts_ref_seq OWNER TO postgres;

--
-- Name: sale_wise_profit_view; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.sale_wise_profit_view AS
 WITH sold_serials AS (
         SELECT su.sold_unit_id,
            su.sold_price,
            pu.serial_number,
            si.sales_item_id,
            s.sales_invoice_id,
            s.invoice_date AS sale_date,
            i.item_name,
            i.item_code,
            i.brand,
            i.category,
            si.item_id
           FROM ((((public.soldunits su
             JOIN public.purchaseunits pu ON ((su.unit_id = pu.unit_id)))
             JOIN public.salesitems si ON ((su.sales_item_id = si.sales_item_id)))
             JOIN public.salesinvoices s ON ((si.sales_invoice_id = s.sales_invoice_id)))
             JOIN public.items i ON ((si.item_id = i.item_id)))
          WHERE ((s.invoice_date >= '2025-10-17'::date) AND (s.invoice_date <= '2025-10-31'::date))
        ), purchased_serials AS (
         SELECT pu.unit_id,
            pu.serial_number,
            pi.purchase_item_id,
            p.purchase_invoice_id,
            p.invoice_date AS purchase_date,
            p.vendor_id,
            i.item_id,
            i.item_name,
            pi.unit_price AS purchase_price
           FROM (((public.purchaseunits pu
             JOIN public.purchaseitems pi ON ((pu.purchase_item_id = pi.purchase_item_id)))
             JOIN public.purchaseinvoices p ON ((pi.purchase_invoice_id = p.purchase_invoice_id)))
             JOIN public.items i ON ((pi.item_id = i.item_id)))
        )
 SELECT ss.sale_date,
    ss.serial_number,
    ss.item_name,
    ss.sold_price AS sale_price,
    ps.purchase_price,
    round((ss.sold_price - ps.purchase_price), 2) AS profit_loss,
        CASE
            WHEN (ps.purchase_price > (0)::numeric) THEN round((((ss.sold_price - ps.purchase_price) / ps.purchase_price) * (100)::numeric), 2)
            ELSE NULL::numeric
        END AS profit_loss_percent,
    v.party_name AS vendor_name,
    ps.purchase_date
   FROM ((sold_serials ss
     LEFT JOIN purchased_serials ps ON (((ss.serial_number)::text = (ps.serial_number)::text)))
     LEFT JOIN public.parties v ON ((ps.vendor_id = v.party_id)))
  ORDER BY ss.sale_date, ss.item_name, ss.serial_number;


ALTER VIEW public.sale_wise_profit_view OWNER TO postgres;

--
-- Name: salesinvoices_sales_invoice_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.salesinvoices_sales_invoice_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.salesinvoices_sales_invoice_id_seq OWNER TO postgres;

--
-- Name: salesinvoices_sales_invoice_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.salesinvoices_sales_invoice_id_seq OWNED BY public.salesinvoices.sales_invoice_id;


--
-- Name: salesitems_sales_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.salesitems_sales_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.salesitems_sales_item_id_seq OWNER TO postgres;

--
-- Name: salesitems_sales_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.salesitems_sales_item_id_seq OWNED BY public.salesitems.sales_item_id;


--
-- Name: salesreturnitems; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.salesreturnitems (
    return_item_id bigint NOT NULL,
    sales_return_id bigint NOT NULL,
    item_id bigint NOT NULL,
    sold_price numeric(12,2) NOT NULL,
    cost_price numeric(12,2) NOT NULL,
    serial_number character varying(100) NOT NULL
);


ALTER TABLE public.salesreturnitems OWNER TO postgres;

--
-- Name: salesreturnitems_return_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.salesreturnitems_return_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.salesreturnitems_return_item_id_seq OWNER TO postgres;

--
-- Name: salesreturnitems_return_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.salesreturnitems_return_item_id_seq OWNED BY public.salesreturnitems.return_item_id;


--
-- Name: salesreturns; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.salesreturns (
    sales_return_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    return_date date DEFAULT CURRENT_DATE NOT NULL,
    total_amount numeric(14,2) DEFAULT 0 NOT NULL,
    journal_id bigint
);


ALTER TABLE public.salesreturns OWNER TO postgres;

--
-- Name: salesreturns_sales_return_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.salesreturns_sales_return_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.salesreturns_sales_return_id_seq OWNER TO postgres;

--
-- Name: salesreturns_sales_return_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.salesreturns_sales_return_id_seq OWNED BY public.salesreturns.sales_return_id;


--
-- Name: soldunits_sold_unit_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.soldunits_sold_unit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.soldunits_sold_unit_id_seq OWNER TO postgres;

--
-- Name: soldunits_sold_unit_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.soldunits_sold_unit_id_seq OWNED BY public.soldunits.sold_unit_id;


--
-- Name: standing_company_worth_view; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.standing_company_worth_view AS
 WITH journal_summary AS (
         SELECT jl.account_id,
            jl.party_id,
            COALESCE(sum(jl.debit), (0)::numeric) AS debit,
            COALESCE(sum(jl.credit), (0)::numeric) AS credit
           FROM public.journallines jl
          GROUP BY jl.account_id, jl.party_id
        ), account_totals AS (
         SELECT coa.account_id,
            coa.account_code,
            coa.account_name,
            coa.account_type,
            COALESCE(sum(js.debit), (0)::numeric) AS total_debit,
            COALESCE(sum(js.credit), (0)::numeric) AS total_credit
           FROM (public.chartofaccounts coa
             LEFT JOIN journal_summary js ON (((coa.account_id = js.account_id) AND (((coa.account_name)::text = ANY (ARRAY[('Accounts Receivable'::character varying)::text, ('Accounts Payable'::character varying)::text])) OR (js.party_id IS NULL)))))
          WHERE (NOT (coa.account_id IN ( SELECT DISTINCT p.ap_account_id
                   FROM public.parties p
                  WHERE (((p.party_type)::text = 'Expense'::text) AND (p.ap_account_id IS NOT NULL)))))
          GROUP BY coa.account_id, coa.account_code, coa.account_name, coa.account_type
        ), party_totals AS (
         SELECT p.party_id,
            p.party_name,
            p.party_type,
            COALESCE(sum(js.debit), (0)::numeric) AS total_debit,
            COALESCE(sum(js.credit), (0)::numeric) AS total_credit,
            (COALESCE(sum(js.debit), (0)::numeric) - COALESCE(sum(js.credit), (0)::numeric)) AS balance
           FROM (public.parties p
             LEFT JOIN journal_summary js ON ((js.party_id = p.party_id)))
          GROUP BY p.party_id, p.party_name, p.party_type
        ), classified_parties AS (
         SELECT pt.party_id,
            pt.party_name,
            pt.party_type,
            pt.total_debit,
            pt.total_credit,
            pt.balance,
                CASE
                    WHEN (((pt.party_type)::text = 'Customer'::text) AND (pt.balance < (0)::numeric)) THEN 'Accounts Payable'::text
                    WHEN (((pt.party_type)::text = 'Vendor'::text) AND (pt.balance > (0)::numeric)) THEN 'Accounts Receivable'::text
                    WHEN ((pt.party_type)::text = 'Both'::text) THEN
                    CASE
                        WHEN (pt.balance >= (0)::numeric) THEN 'Accounts Receivable'::text
                        ELSE 'Accounts Payable'::text
                    END
                    WHEN ((pt.party_type)::text = 'Customer'::text) THEN 'Accounts Receivable'::text
                    WHEN ((pt.party_type)::text = 'Vendor'::text) THEN 'Accounts Payable'::text
                    ELSE 'Expense Party'::text
                END AS effective_type
           FROM party_totals pt
        ), control_adjustment AS (
         SELECT classified_parties.effective_type AS account_name,
            sum(GREATEST(classified_parties.balance, (0)::numeric)) AS debit_side,
            sum(abs(LEAST(classified_parties.balance, (0)::numeric))) AS credit_side
           FROM classified_parties
          WHERE (classified_parties.effective_type = ANY (ARRAY['Accounts Receivable'::text, 'Accounts Payable'::text]))
          GROUP BY classified_parties.effective_type
        ), merged_totals AS (
         SELECT coa.account_type,
                CASE
                    WHEN ((coa.account_type)::text = ANY (ARRAY[('Asset'::character varying)::text, ('Expense'::character varying)::text])) THEN (COALESCE(ca.debit_side, at.total_debit, (0)::numeric) - COALESCE(ca.credit_side, at.total_credit, (0)::numeric))
                    WHEN ((coa.account_type)::text = ANY (ARRAY[('Liability'::character varying)::text, ('Equity'::character varying)::text, ('Revenue'::character varying)::text])) THEN (COALESCE(ca.credit_side, at.total_credit, (0)::numeric) - COALESCE(ca.debit_side, at.total_debit, (0)::numeric))
                    ELSE (0)::numeric
                END AS net_balance
           FROM ((account_totals at
             JOIN public.chartofaccounts coa ON ((at.account_id = coa.account_id)))
             LEFT JOIN control_adjustment ca ON ((ca.account_name = (coa.account_name)::text)))
        ), summary AS (
         SELECT merged_totals.account_type,
            sum(merged_totals.net_balance) AS total
           FROM merged_totals
          GROUP BY merged_totals.account_type
        ), party_expenses AS (
         SELECT sum(classified_parties.balance) AS total_party_expenses
           FROM classified_parties
          WHERE (classified_parties.effective_type = 'Expense Party'::text)
        ), totals AS (
         SELECT COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Asset'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) AS assets,
            COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Liability'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) AS liabilities,
            COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Equity'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) AS equity,
            COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Revenue'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) AS revenue,
            (COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Expense'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) + COALESCE(( SELECT party_expenses.total_party_expenses
                   FROM party_expenses), (0)::numeric)) AS expenses
           FROM summary
        )
 SELECT json_build_object('financial_position', json_build_object('total_assets', round(assets, 2), 'total_liabilities', round(liabilities, 2), 'total_equity', round(equity, 2), 'net_worth', round((assets - liabilities), 2)), 'profit_and_loss', json_build_object('total_revenue', round(revenue, 2), 'total_expenses', round(expenses, 2), 'net_profit_loss', round((revenue - expenses), 2))) AS company_standing
   FROM totals;


ALTER VIEW public.standing_company_worth_view OWNER TO postgres;

--
-- Name: stock_report; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.stock_report AS
 WITH stock AS (
         SELECT i.item_id,
            i.item_name,
            count(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
            pu.serial_number,
            row_number() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
           FROM ((public.purchaseunits pu
             JOIN public.purchaseitems pit ON ((pu.purchase_item_id = pit.purchase_item_id)))
             JOIN public.items i ON ((pit.item_id = i.item_id)))
          WHERE (pu.in_stock = true)
        )
 SELECT
        CASE
            WHEN (rn = 1) THEN (item_id)::text
            ELSE ''::text
        END AS item_id,
        CASE
            WHEN (rn = 1) THEN item_name
            ELSE ''::character varying
        END AS item_name,
        CASE
            WHEN (rn = 1) THEN (quantity)::text
            ELSE ''::text
        END AS quantity,
    serial_number
   FROM stock
  ORDER BY ((item_id)::integer), rn;


ALTER VIEW public.stock_report OWNER TO postgres;

--
-- Name: stock_worth_report; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.stock_worth_report AS
 WITH stock AS (
         SELECT i.item_id,
            i.item_name,
            count(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
            pu.serial_number,
            pit.unit_price AS purchase_price,
            i.sale_price AS market_price,
            row_number() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
           FROM ((public.purchaseunits pu
             JOIN public.purchaseitems pit ON ((pu.purchase_item_id = pit.purchase_item_id)))
             JOIN public.items i ON ((pit.item_id = i.item_id)))
          WHERE (pu.in_stock = true)
        ), running AS (
         SELECT stock.item_id,
            stock.item_name,
            stock.quantity,
            stock.serial_number,
            stock.purchase_price,
            stock.market_price,
            sum(stock.purchase_price) OVER (ORDER BY stock.item_id, stock.rn) AS running_total_purchase,
            sum(stock.market_price) OVER (ORDER BY stock.item_id, stock.rn) AS running_total_market,
            stock.rn
           FROM stock
        )
 SELECT
        CASE
            WHEN (rn = 1) THEN (item_id)::text
            ELSE ''::text
        END AS item_id,
        CASE
            WHEN (rn = 1) THEN item_name
            ELSE ''::character varying
        END AS item_name,
        CASE
            WHEN (rn = 1) THEN (quantity)::text
            ELSE ''::text
        END AS quantity,
    serial_number,
    purchase_price,
    market_price,
    running_total_purchase,
    running_total_market
   FROM running
  ORDER BY ((item_id)::integer), rn;


ALTER VIEW public.stock_worth_report OWNER TO postgres;

--
-- Name: stockmovements; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.stockmovements (
    movement_id bigint NOT NULL,
    item_id bigint NOT NULL,
    serial_number text,
    movement_type character varying(20) NOT NULL,
    reference_type character varying(50),
    reference_id bigint,
    movement_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    quantity integer NOT NULL,
    CONSTRAINT stockmovements_movement_type_check CHECK (((movement_type)::text = ANY (ARRAY[('IN'::character varying)::text, ('OUT'::character varying)::text])))
);


ALTER TABLE public.stockmovements OWNER TO postgres;

--
-- Name: stockmovements_movement_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.stockmovements_movement_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.stockmovements_movement_id_seq OWNER TO postgres;

--
-- Name: stockmovements_movement_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.stockmovements_movement_id_seq OWNED BY public.stockmovements.movement_id;


--
-- Name: vw_trial_balance; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.vw_trial_balance AS
 WITH journal_summary AS (
         SELECT jl.account_id,
            jl.party_id,
            COALESCE(sum(jl.debit), (0)::numeric) AS debit,
            COALESCE(sum(jl.credit), (0)::numeric) AS credit
           FROM public.journallines jl
          GROUP BY jl.account_id, jl.party_id
        ), account_totals AS (
         SELECT coa.account_id,
            coa.account_code,
            coa.account_name,
            coa.account_type,
            sum(js.debit) AS total_debit,
            sum(js.credit) AS total_credit
           FROM (public.chartofaccounts coa
             LEFT JOIN journal_summary js ON (((coa.account_id = js.account_id) AND (((coa.account_name)::text = ANY (ARRAY[('Accounts Receivable'::character varying)::text, ('Accounts Payable'::character varying)::text])) OR (js.party_id IS NULL)))))
          WHERE (NOT (coa.account_id IN ( SELECT DISTINCT p.ap_account_id
                   FROM public.parties p
                  WHERE (((p.party_type)::text = 'Expense'::text) AND (p.ap_account_id IS NOT NULL)))))
          GROUP BY coa.account_id, coa.account_code, coa.account_name, coa.account_type
        ), party_totals AS (
         SELECT p.party_id,
            p.party_name,
            p.party_type,
            COALESCE(sum(js.debit), (0)::numeric) AS total_debit,
            COALESCE(sum(js.credit), (0)::numeric) AS total_credit,
            (COALESCE(sum(js.debit), (0)::numeric) - COALESCE(sum(js.credit), (0)::numeric)) AS balance
           FROM (public.parties p
             LEFT JOIN journal_summary js ON ((js.party_id = p.party_id)))
          GROUP BY p.party_id, p.party_name, p.party_type
        ), classified_parties AS (
         SELECT pt.party_id,
            pt.party_name,
            pt.party_type,
            pt.total_debit,
            pt.total_credit,
            pt.balance,
                CASE
                    WHEN (((pt.party_type)::text = 'Customer'::text) AND (pt.balance < (0)::numeric)) THEN 'Accounts Payable'::text
                    WHEN (((pt.party_type)::text = 'Vendor'::text) AND (pt.balance > (0)::numeric)) THEN 'Accounts Receivable'::text
                    WHEN ((pt.party_type)::text = 'Both'::text) THEN
                    CASE
                        WHEN (pt.balance >= (0)::numeric) THEN 'Accounts Receivable'::text
                        ELSE 'Accounts Payable'::text
                    END
                    WHEN ((pt.party_type)::text = 'Customer'::text) THEN 'Accounts Receivable'::text
                    WHEN ((pt.party_type)::text = 'Vendor'::text) THEN 'Accounts Payable'::text
                    ELSE 'Expense Party'::text
                END AS effective_type
           FROM party_totals pt
        ), control_adjustment AS (
         SELECT classified_parties.effective_type AS account_name,
            sum(GREATEST(classified_parties.balance, (0)::numeric)) AS debit_side,
            sum(abs(LEAST(classified_parties.balance, (0)::numeric))) AS credit_side
           FROM classified_parties
          WHERE (classified_parties.effective_type = ANY (ARRAY['Accounts Receivable'::text, 'Accounts Payable'::text]))
          GROUP BY classified_parties.effective_type
        )
 SELECT at.account_code AS code,
    at.account_name AS name,
    at.account_type AS type,
    COALESCE(ca.debit_side, at.total_debit, (0)::numeric) AS total_debit,
    COALESCE(ca.credit_side, at.total_credit, (0)::numeric) AS total_credit,
    (COALESCE(ca.debit_side, at.total_debit, (0)::numeric) - COALESCE(ca.credit_side, at.total_credit, (0)::numeric)) AS balance
   FROM (account_totals at
     LEFT JOIN control_adjustment ca ON ((ca.account_name = (at.account_name)::text)))
UNION ALL
 SELECT NULL::character varying AS code,
    pt.party_name AS name,
    pt.effective_type AS type,
    pt.total_debit,
    pt.total_credit,
    pt.balance
   FROM classified_parties pt
  WHERE ((pt.total_debit <> (0)::numeric) OR (pt.total_credit <> (0)::numeric))
  ORDER BY 1 NULLS FIRST, 2;


ALTER VIEW public.vw_trial_balance OWNER TO postgres;

--
-- Name: chartofaccounts account_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chartofaccounts ALTER COLUMN account_id SET DEFAULT nextval('public.chartofaccounts_account_id_seq'::regclass);


--
-- Name: items item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.items ALTER COLUMN item_id SET DEFAULT nextval('public.items_item_id_seq'::regclass);


--
-- Name: journalentries journal_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journalentries ALTER COLUMN journal_id SET DEFAULT nextval('public.journalentries_journal_id_seq'::regclass);


--
-- Name: journallines line_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journallines ALTER COLUMN line_id SET DEFAULT nextval('public.journallines_line_id_seq'::regclass);


--
-- Name: parties party_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.parties ALTER COLUMN party_id SET DEFAULT nextval('public.parties_party_id_seq'::regclass);


--
-- Name: payments payment_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments ALTER COLUMN payment_id SET DEFAULT nextval('public.payments_payment_id_seq'::regclass);


--
-- Name: purchaseinvoices purchase_invoice_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseinvoices ALTER COLUMN purchase_invoice_id SET DEFAULT nextval('public.purchaseinvoices_purchase_invoice_id_seq'::regclass);


--
-- Name: purchaseitems purchase_item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseitems ALTER COLUMN purchase_item_id SET DEFAULT nextval('public.purchaseitems_purchase_item_id_seq'::regclass);


--
-- Name: purchasereturnitems return_item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturnitems ALTER COLUMN return_item_id SET DEFAULT nextval('public.purchasereturnitems_return_item_id_seq'::regclass);


--
-- Name: purchasereturns purchase_return_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturns ALTER COLUMN purchase_return_id SET DEFAULT nextval('public.purchasereturns_purchase_return_id_seq'::regclass);


--
-- Name: purchaseunits unit_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseunits ALTER COLUMN unit_id SET DEFAULT nextval('public.purchaseunits_unit_id_seq'::regclass);


--
-- Name: receipts receipt_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipts ALTER COLUMN receipt_id SET DEFAULT nextval('public.receipts_receipt_id_seq'::regclass);


--
-- Name: salesinvoices sales_invoice_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesinvoices ALTER COLUMN sales_invoice_id SET DEFAULT nextval('public.salesinvoices_sales_invoice_id_seq'::regclass);


--
-- Name: salesitems sales_item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesitems ALTER COLUMN sales_item_id SET DEFAULT nextval('public.salesitems_sales_item_id_seq'::regclass);


--
-- Name: salesreturnitems return_item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturnitems ALTER COLUMN return_item_id SET DEFAULT nextval('public.salesreturnitems_return_item_id_seq'::regclass);


--
-- Name: salesreturns sales_return_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturns ALTER COLUMN sales_return_id SET DEFAULT nextval('public.salesreturns_sales_return_id_seq'::regclass);


--
-- Name: soldunits sold_unit_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.soldunits ALTER COLUMN sold_unit_id SET DEFAULT nextval('public.soldunits_sold_unit_id_seq'::regclass);


--
-- Name: stockmovements movement_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stockmovements ALTER COLUMN movement_id SET DEFAULT nextval('public.stockmovements_movement_id_seq'::regclass);


--
-- Data for Name: auth_group; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_group (id, name) FROM stdin;
1	view_only_users
\.


--
-- Data for Name: auth_group_permissions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_group_permissions (id, group_id, permission_id) FROM stdin;
\.


--
-- Data for Name: auth_permission; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_permission (id, name, content_type_id, codename) FROM stdin;
1	Can add log entry	1	add_logentry
2	Can change log entry	1	change_logentry
3	Can delete log entry	1	delete_logentry
4	Can view log entry	1	view_logentry
5	Can add permission	3	add_permission
6	Can change permission	3	change_permission
7	Can delete permission	3	delete_permission
8	Can view permission	3	view_permission
9	Can add group	2	add_group
10	Can change group	2	change_group
11	Can delete group	2	delete_group
12	Can view group	2	view_group
13	Can add user	4	add_user
14	Can change user	4	change_user
15	Can delete user	4	delete_user
16	Can view user	4	view_user
17	Can add content type	5	add_contenttype
18	Can change content type	5	change_contenttype
19	Can delete content type	5	delete_contenttype
20	Can view content type	5	view_contenttype
21	Can add session	6	add_session
22	Can change session	6	change_session
23	Can delete session	6	delete_session
24	Can view session	6	view_session
\.


--
-- Data for Name: auth_user; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_user (id, password, last_login, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined) FROM stdin;
1	pbkdf2_sha256$1200000$RXhGhMVbAN430kGibRWclp$0bFixmZrJQUORkd30ou1uNsx/1vRuA7fHI83CR9zly0=	2025-12-09 14:28:39.695832+00	t	financee_admin				t	t	2025-12-09 14:12:23.026824+00
2	pbkdf2_sha256$1200000$BUJHK6vNtJlrCuMQpstztc$hWijcN9qC3RkpbTTqWPI18AYSAtPiAy/+mpMc2M0TUs=	2025-12-12 14:38:33.392933+00	f	saqib				f	t	2025-12-09 14:31:16.44303+00
3	pbkdf2_sha256$1200000$mvVrQ0Eu8HeBIySSNm2PBw$yT7x2mFdxxqDhCVgHyqlnc/O/fLbJo5Imf5i2fHkhtA=	2025-12-17 13:24:07.817552+00	f	dubaiOffice				f	t	2025-12-09 14:35:42+00
\.


--
-- Data for Name: auth_user_groups; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_user_groups (id, user_id, group_id) FROM stdin;
1	3	1
\.


--
-- Data for Name: auth_user_user_permissions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_user_user_permissions (id, user_id, permission_id) FROM stdin;
\.


--
-- Data for Name: chartofaccounts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.chartofaccounts (account_id, account_code, account_name, account_type, parent_account, date_created) FROM stdin;
1	2000	Accounts Payable	Liability	\N	2025-12-09 14:18:14.47586
2	3000	Owner's Capital	Equity	\N	2025-12-09 14:18:14.478347
3	4000	Sales Revenue	Revenue	\N	2025-12-09 14:18:14.479575
4	5000	Cost of Goods Sold	Expense	\N	2025-12-09 14:18:14.480735
5	1000	Cash	Asset	\N	2025-12-09 14:21:31.913409
6	1200	Accounts Receivable	Asset	\N	2025-12-09 14:21:31.913409
7	1400	Inventory	Asset	\N	2025-12-09 14:21:31.913409
\.


--
-- Data for Name: django_admin_log; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.django_admin_log (id, action_time, object_id, object_repr, action_flag, change_message, content_type_id, user_id) FROM stdin;
1	2025-12-09 14:29:18.489428+00	1	view_only_users	1	[{"added": {}}]	2	1
2	2025-12-09 14:31:17.452744+00	2	saqib	1	[{"added": {}}]	4	1
3	2025-12-09 14:35:43.457174+00	3	dubaiOffice	1	[{"added": {}}]	4	1
4	2025-12-09 14:36:03.114181+00	3	dubaiOffice	2	[{"changed": {"fields": ["Groups"]}}]	4	1
\.


--
-- Data for Name: django_content_type; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.django_content_type (id, app_label, model) FROM stdin;
1	admin	logentry
2	auth	group
3	auth	permission
4	auth	user
5	contenttypes	contenttype
6	sessions	session
\.


--
-- Data for Name: django_migrations; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.django_migrations (id, app, name, applied) FROM stdin;
1	contenttypes	0001_initial	2025-12-09 14:11:05.291535+00
2	auth	0001_initial	2025-12-09 14:11:05.400142+00
3	admin	0001_initial	2025-12-09 14:11:05.450774+00
4	admin	0002_logentry_remove_auto_add	2025-12-09 14:11:05.458359+00
5	admin	0003_logentry_add_action_flag_choices	2025-12-09 14:11:05.466011+00
6	contenttypes	0002_remove_content_type_name	2025-12-09 14:11:05.48093+00
7	auth	0002_alter_permission_name_max_length	2025-12-09 14:11:05.489533+00
8	auth	0003_alter_user_email_max_length	2025-12-09 14:11:05.49789+00
9	auth	0004_alter_user_username_opts	2025-12-09 14:11:05.505418+00
10	auth	0005_alter_user_last_login_null	2025-12-09 14:11:05.515102+00
11	auth	0006_require_contenttypes_0002	2025-12-09 14:11:05.517146+00
12	auth	0007_alter_validators_add_error_messages	2025-12-09 14:11:05.524532+00
13	auth	0008_alter_user_username_max_length	2025-12-09 14:11:05.537983+00
14	auth	0009_alter_user_last_name_max_length	2025-12-09 14:11:05.546726+00
15	auth	0010_alter_group_name_max_length	2025-12-09 14:11:05.555501+00
16	auth	0011_update_proxy_permissions	2025-12-09 14:11:05.562354+00
17	auth	0012_alter_user_first_name_max_length	2025-12-09 14:11:05.570731+00
18	sessions	0001_initial	2025-12-09 14:11:05.5912+00
\.


--
-- Data for Name: django_session; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.django_session (session_key, session_data, expire_date) FROM stdin;
1up5w3niqp078xdx276k97dia5xw5g7x	.eJxVjEEOwiAQRe_C2pABCi0u3fcMZIYZbNXQpLQr491Nky50-997_60S7tuU9iZrmlldlVGX340wP6UegB9Y74vOS93WmfSh6JM2PS4sr9vp_h1M2KajJsjiBwc0uD7GUrrIPVsHGQQBQxkMBUfeW0RXuhA5ZgYjJQfbkXj1-QLwJzhf:1vSyhj:K33PVH_7EVJgi1Fg0JgQ_MheICS6PgaEY_eX-4pAz0I	2025-12-23 14:28:39.698208+00
cusvv0zy2ll2elmuncd4ppa3ky88ain0	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vSypk:7aHf8XMyMVD7ByNtZSKoAN7hvyLp554P9q4Y-9dxAds	2025-12-23 14:36:56.397601+00
59gb23ubf8bw9h4kdvtsktvc8www5g5a	.eJxVjMsOgjAUBf-la9NA6YO4dO83NPdVi5o2obAi_ruQsNDtmZmzqQjrkuPaZI4Tq6sy6vK7IdBLygH4CeVRNdWyzBPqQ9EnbfpeWd630_07yNDyXqdB7CA0ovQ4Wk8sBrwjFwKgQZdAKHQBxIPx5Mj03jLvZuJkOwdBfb4VyTkc:1vT3Sx:yKt5Ljl2IQjcS__pi6Uh2OQl1gZ2PdO9ZRw1NIXS8TQ	2025-12-23 19:33:43.624304+00
xkpkwdr9ap6hfwqnxora1nnilctzjlca	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vU49n:ExUAJNtWKHT-RyX72kP0-OFgoL1NBf7IEJulVIvn7y4	2025-12-26 14:30:07.021419+00
bb4jy77wbhedpuyi2xq9l6wh09usafh0	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vU5rx:asrCIEXwhyrngfjCUNvz18KpLqEPabhUshge2LInPoA	2025-12-26 16:19:49.078938+00
kz6dqf8w22uzqcov2h9oz8vhxnccvdn5	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vV6Ea:j8mNWRVYSL68Cze4PehDfXnVJkgKyE-quDkl7Sw5coM	2025-12-29 10:55:20.662494+00
1pq8zp5s9ox5r3cdxa02d6y8n1v6t5sz	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vVrVf:6F_NvU96nncCgskpc7nr6yF5NqSEGipeAt1gzauHQJA	2025-12-31 13:24:07.819811+00
\.


--
-- Data for Name: items; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.items (item_id, item_name, storage, sale_price, item_code, category, brand, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: journalentries; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.journalentries (journal_id, entry_date, description, date_created) FROM stdin;
\.


--
-- Data for Name: journallines; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.journallines (line_id, journal_id, account_id, party_id, debit, credit) FROM stdin;
\.


--
-- Data for Name: parties; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.parties (party_id, party_name, party_type, contact_info, address, ar_account_id, ap_account_id, opening_balance, balance_type, date_created) FROM stdin;
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payments (payment_id, party_id, account_id, amount, payment_date, method, reference_no, journal_id, date_created, notes, description) FROM stdin;
\.


--
-- Data for Name: purchaseinvoices; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchaseinvoices (purchase_invoice_id, vendor_id, invoice_date, total_amount, journal_id) FROM stdin;
\.


--
-- Data for Name: purchaseitems; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchaseitems (purchase_item_id, purchase_invoice_id, item_id, quantity, unit_price) FROM stdin;
\.


--
-- Data for Name: purchasereturnitems; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchasereturnitems (return_item_id, purchase_return_id, item_id, unit_price, serial_number) FROM stdin;
\.


--
-- Data for Name: purchasereturns; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchasereturns (purchase_return_id, vendor_id, return_date, total_amount, journal_id) FROM stdin;
\.


--
-- Data for Name: purchaseunits; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchaseunits (unit_id, purchase_item_id, serial_number, in_stock) FROM stdin;
\.


--
-- Data for Name: receipts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.receipts (receipt_id, party_id, account_id, amount, receipt_date, method, reference_no, journal_id, date_created, notes, description) FROM stdin;
\.


--
-- Data for Name: salesinvoices; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salesinvoices (sales_invoice_id, customer_id, invoice_date, total_amount, journal_id) FROM stdin;
\.


--
-- Data for Name: salesitems; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salesitems (sales_item_id, sales_invoice_id, item_id, quantity, unit_price) FROM stdin;
\.


--
-- Data for Name: salesreturnitems; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salesreturnitems (return_item_id, sales_return_id, item_id, sold_price, cost_price, serial_number) FROM stdin;
\.


--
-- Data for Name: salesreturns; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salesreturns (sales_return_id, customer_id, return_date, total_amount, journal_id) FROM stdin;
\.


--
-- Data for Name: soldunits; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.soldunits (sold_unit_id, sales_item_id, unit_id, sold_price, status) FROM stdin;
\.


--
-- Data for Name: stockmovements; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.stockmovements (movement_id, item_id, serial_number, movement_type, reference_type, reference_id, movement_date, quantity) FROM stdin;
\.


--
-- Name: auth_group_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.auth_group_id_seq', 1, true);


--
-- Name: auth_group_permissions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.auth_group_permissions_id_seq', 1, false);


--
-- Name: auth_permission_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.auth_permission_id_seq', 24, true);


--
-- Name: auth_user_groups_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.auth_user_groups_id_seq', 1, true);


--
-- Name: auth_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.auth_user_id_seq', 3, true);


--
-- Name: auth_user_user_permissions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.auth_user_user_permissions_id_seq', 1, false);


--
-- Name: chartofaccounts_account_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.chartofaccounts_account_id_seq', 16, true);


--
-- Name: django_admin_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.django_admin_log_id_seq', 4, true);


--
-- Name: django_content_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.django_content_type_id_seq', 6, true);


--
-- Name: django_migrations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.django_migrations_id_seq', 18, true);


--
-- Name: items_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.items_item_id_seq', 1, false);


--
-- Name: journalentries_journal_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.journalentries_journal_id_seq', 1, false);


--
-- Name: journallines_line_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.journallines_line_id_seq', 1, false);


--
-- Name: parties_party_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.parties_party_id_seq', 1, false);


--
-- Name: payments_payment_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.payments_payment_id_seq', 1, false);


--
-- Name: payments_ref_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.payments_ref_seq', 1, false);


--
-- Name: purchaseinvoices_purchase_invoice_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchaseinvoices_purchase_invoice_id_seq', 1, false);


--
-- Name: purchaseitems_purchase_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchaseitems_purchase_item_id_seq', 1, false);


--
-- Name: purchasereturnitems_return_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchasereturnitems_return_item_id_seq', 1, false);


--
-- Name: purchasereturns_purchase_return_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchasereturns_purchase_return_id_seq', 1, false);


--
-- Name: purchaseunits_unit_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchaseunits_unit_id_seq', 1, false);


--
-- Name: receipts_receipt_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.receipts_receipt_id_seq', 1, false);


--
-- Name: receipts_ref_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.receipts_ref_seq', 1, false);


--
-- Name: salesinvoices_sales_invoice_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salesinvoices_sales_invoice_id_seq', 1, false);


--
-- Name: salesitems_sales_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salesitems_sales_item_id_seq', 1, false);


--
-- Name: salesreturnitems_return_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salesreturnitems_return_item_id_seq', 1, false);


--
-- Name: salesreturns_sales_return_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salesreturns_sales_return_id_seq', 1, false);


--
-- Name: soldunits_sold_unit_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.soldunits_sold_unit_id_seq', 1, false);


--
-- Name: stockmovements_movement_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.stockmovements_movement_id_seq', 1, false);


--
-- Name: auth_group auth_group_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group
    ADD CONSTRAINT auth_group_name_key UNIQUE (name);


--
-- Name: auth_group_permissions auth_group_permissions_group_id_permission_id_0cd325b0_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_group_id_permission_id_0cd325b0_uniq UNIQUE (group_id, permission_id);


--
-- Name: auth_group_permissions auth_group_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_pkey PRIMARY KEY (id);


--
-- Name: auth_group auth_group_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group
    ADD CONSTRAINT auth_group_pkey PRIMARY KEY (id);


--
-- Name: auth_permission auth_permission_content_type_id_codename_01ab375a_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_content_type_id_codename_01ab375a_uniq UNIQUE (content_type_id, codename);


--
-- Name: auth_permission auth_permission_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_pkey PRIMARY KEY (id);


--
-- Name: auth_user_groups auth_user_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_groups
    ADD CONSTRAINT auth_user_groups_pkey PRIMARY KEY (id);


--
-- Name: auth_user_groups auth_user_groups_user_id_group_id_94350c0c_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_groups
    ADD CONSTRAINT auth_user_groups_user_id_group_id_94350c0c_uniq UNIQUE (user_id, group_id);


--
-- Name: auth_user auth_user_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user
    ADD CONSTRAINT auth_user_pkey PRIMARY KEY (id);


--
-- Name: auth_user_user_permissions auth_user_user_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_user_permissions
    ADD CONSTRAINT auth_user_user_permissions_pkey PRIMARY KEY (id);


--
-- Name: auth_user_user_permissions auth_user_user_permissions_user_id_permission_id_14a6b632_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_user_permissions
    ADD CONSTRAINT auth_user_user_permissions_user_id_permission_id_14a6b632_uniq UNIQUE (user_id, permission_id);


--
-- Name: auth_user auth_user_username_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user
    ADD CONSTRAINT auth_user_username_key UNIQUE (username);


--
-- Name: chartofaccounts chartofaccounts_account_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chartofaccounts
    ADD CONSTRAINT chartofaccounts_account_code_key UNIQUE (account_code);


--
-- Name: chartofaccounts chartofaccounts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chartofaccounts
    ADD CONSTRAINT chartofaccounts_pkey PRIMARY KEY (account_id);


--
-- Name: django_admin_log django_admin_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_pkey PRIMARY KEY (id);


--
-- Name: django_content_type django_content_type_app_label_model_76bd3d3b_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_content_type
    ADD CONSTRAINT django_content_type_app_label_model_76bd3d3b_uniq UNIQUE (app_label, model);


--
-- Name: django_content_type django_content_type_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_content_type
    ADD CONSTRAINT django_content_type_pkey PRIMARY KEY (id);


--
-- Name: django_migrations django_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_migrations
    ADD CONSTRAINT django_migrations_pkey PRIMARY KEY (id);


--
-- Name: django_session django_session_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_session
    ADD CONSTRAINT django_session_pkey PRIMARY KEY (session_key);


--
-- Name: items items_item_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_item_code_key UNIQUE (item_code);


--
-- Name: items items_item_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_item_name_key UNIQUE (item_name);


--
-- Name: items items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_pkey PRIMARY KEY (item_id);


--
-- Name: journalentries journalentries_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journalentries
    ADD CONSTRAINT journalentries_pkey PRIMARY KEY (journal_id);


--
-- Name: journallines journallines_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journallines
    ADD CONSTRAINT journallines_pkey PRIMARY KEY (line_id);


--
-- Name: parties parties_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_pkey PRIMARY KEY (party_id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (payment_id);


--
-- Name: purchaseinvoices purchaseinvoices_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseinvoices
    ADD CONSTRAINT purchaseinvoices_pkey PRIMARY KEY (purchase_invoice_id);


--
-- Name: purchaseitems purchaseitems_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseitems
    ADD CONSTRAINT purchaseitems_pkey PRIMARY KEY (purchase_item_id);


--
-- Name: purchasereturnitems purchasereturnitems_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturnitems
    ADD CONSTRAINT purchasereturnitems_pkey PRIMARY KEY (return_item_id);


--
-- Name: purchasereturns purchasereturns_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturns
    ADD CONSTRAINT purchasereturns_pkey PRIMARY KEY (purchase_return_id);


--
-- Name: purchaseunits purchaseunits_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseunits
    ADD CONSTRAINT purchaseunits_pkey PRIMARY KEY (unit_id);


--
-- Name: purchaseunits purchaseunits_serial_number_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseunits
    ADD CONSTRAINT purchaseunits_serial_number_key UNIQUE (serial_number);


--
-- Name: receipts receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_pkey PRIMARY KEY (receipt_id);


--
-- Name: salesinvoices salesinvoices_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesinvoices
    ADD CONSTRAINT salesinvoices_pkey PRIMARY KEY (sales_invoice_id);


--
-- Name: salesitems salesitems_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesitems
    ADD CONSTRAINT salesitems_pkey PRIMARY KEY (sales_item_id);


--
-- Name: salesreturnitems salesreturnitems_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturnitems
    ADD CONSTRAINT salesreturnitems_pkey PRIMARY KEY (return_item_id);


--
-- Name: salesreturns salesreturns_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturns
    ADD CONSTRAINT salesreturns_pkey PRIMARY KEY (sales_return_id);


--
-- Name: soldunits soldunits_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.soldunits
    ADD CONSTRAINT soldunits_pkey PRIMARY KEY (sold_unit_id);


--
-- Name: stockmovements stockmovements_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stockmovements
    ADD CONSTRAINT stockmovements_pkey PRIMARY KEY (movement_id);


--
-- Name: parties unique_party_name; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT unique_party_name UNIQUE (party_name);


--
-- Name: auth_group_name_a6ea08ec_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_group_name_a6ea08ec_like ON public.auth_group USING btree (name varchar_pattern_ops);


--
-- Name: auth_group_permissions_group_id_b120cbf9; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_group_permissions_group_id_b120cbf9 ON public.auth_group_permissions USING btree (group_id);


--
-- Name: auth_group_permissions_permission_id_84c5c92e; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_group_permissions_permission_id_84c5c92e ON public.auth_group_permissions USING btree (permission_id);


--
-- Name: auth_permission_content_type_id_2f476e4b; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_permission_content_type_id_2f476e4b ON public.auth_permission USING btree (content_type_id);


--
-- Name: auth_user_groups_group_id_97559544; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_groups_group_id_97559544 ON public.auth_user_groups USING btree (group_id);


--
-- Name: auth_user_groups_user_id_6a12ed8b; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_groups_user_id_6a12ed8b ON public.auth_user_groups USING btree (user_id);


--
-- Name: auth_user_user_permissions_permission_id_1fbb5f2c; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_user_permissions_permission_id_1fbb5f2c ON public.auth_user_user_permissions USING btree (permission_id);


--
-- Name: auth_user_user_permissions_user_id_a95ead1b; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_user_permissions_user_id_a95ead1b ON public.auth_user_user_permissions USING btree (user_id);


--
-- Name: auth_user_username_6821ab7c_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_username_6821ab7c_like ON public.auth_user USING btree (username varchar_pattern_ops);


--
-- Name: django_admin_log_content_type_id_c4bce8eb; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX django_admin_log_content_type_id_c4bce8eb ON public.django_admin_log USING btree (content_type_id);


--
-- Name: django_admin_log_user_id_c564eba6; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX django_admin_log_user_id_c564eba6 ON public.django_admin_log USING btree (user_id);


--
-- Name: django_session_expire_date_a5c62663; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX django_session_expire_date_a5c62663 ON public.django_session USING btree (expire_date);


--
-- Name: django_session_session_key_c0390e0f_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX django_session_session_key_c0390e0f_like ON public.django_session USING btree (session_key varchar_pattern_ops);


--
-- Name: parties trg_party_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_party_insert AFTER INSERT ON public.parties FOR EACH ROW EXECUTE FUNCTION public.trg_party_opening_balance();


--
-- Name: payments trg_payment_delete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_payment_delete AFTER DELETE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.trg_payment_journal();


--
-- Name: payments trg_payment_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_payment_insert AFTER INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION public.trg_payment_journal();


--
-- Name: payments trg_payment_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_payment_update AFTER UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.trg_payment_journal();


--
-- Name: receipts trg_receipt_delete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_receipt_delete AFTER DELETE ON public.receipts FOR EACH ROW EXECUTE FUNCTION public.trg_receipt_journal();


--
-- Name: receipts trg_receipt_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_receipt_insert AFTER INSERT ON public.receipts FOR EACH ROW EXECUTE FUNCTION public.trg_receipt_journal();


--
-- Name: receipts trg_receipt_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_receipt_update AFTER UPDATE ON public.receipts FOR EACH ROW EXECUTE FUNCTION public.trg_receipt_journal();


--
-- Name: auth_group_permissions auth_group_permissio_permission_id_84c5c92e_fk_auth_perm; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissio_permission_id_84c5c92e_fk_auth_perm FOREIGN KEY (permission_id) REFERENCES public.auth_permission(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_group_permissions auth_group_permissions_group_id_b120cbf9_fk_auth_group_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_group_id_b120cbf9_fk_auth_group_id FOREIGN KEY (group_id) REFERENCES public.auth_group(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_permission auth_permission_content_type_id_2f476e4b_fk_django_co; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_content_type_id_2f476e4b_fk_django_co FOREIGN KEY (content_type_id) REFERENCES public.django_content_type(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_user_groups auth_user_groups_group_id_97559544_fk_auth_group_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_groups
    ADD CONSTRAINT auth_user_groups_group_id_97559544_fk_auth_group_id FOREIGN KEY (group_id) REFERENCES public.auth_group(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_user_groups auth_user_groups_user_id_6a12ed8b_fk_auth_user_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_groups
    ADD CONSTRAINT auth_user_groups_user_id_6a12ed8b_fk_auth_user_id FOREIGN KEY (user_id) REFERENCES public.auth_user(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_user_user_permissions auth_user_user_permi_permission_id_1fbb5f2c_fk_auth_perm; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_user_permissions
    ADD CONSTRAINT auth_user_user_permi_permission_id_1fbb5f2c_fk_auth_perm FOREIGN KEY (permission_id) REFERENCES public.auth_permission(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_user_user_permissions auth_user_user_permissions_user_id_a95ead1b_fk_auth_user_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_user_permissions
    ADD CONSTRAINT auth_user_user_permissions_user_id_a95ead1b_fk_auth_user_id FOREIGN KEY (user_id) REFERENCES public.auth_user(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: chartofaccounts chartofaccounts_parent_account_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chartofaccounts
    ADD CONSTRAINT chartofaccounts_parent_account_fkey FOREIGN KEY (parent_account) REFERENCES public.chartofaccounts(account_id) ON DELETE SET NULL;


--
-- Name: django_admin_log django_admin_log_content_type_id_c4bce8eb_fk_django_co; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_content_type_id_c4bce8eb_fk_django_co FOREIGN KEY (content_type_id) REFERENCES public.django_content_type(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: django_admin_log django_admin_log_user_id_c564eba6_fk_auth_user_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_user_id_c564eba6_fk_auth_user_id FOREIGN KEY (user_id) REFERENCES public.auth_user(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: journallines journallines_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journallines
    ADD CONSTRAINT journallines_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.chartofaccounts(account_id);


--
-- Name: journallines journallines_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journallines
    ADD CONSTRAINT journallines_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE CASCADE;


--
-- Name: journallines journallines_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journallines
    ADD CONSTRAINT journallines_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(party_id) ON DELETE SET NULL;


--
-- Name: parties parties_ap_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_ap_account_id_fkey FOREIGN KEY (ap_account_id) REFERENCES public.chartofaccounts(account_id) ON DELETE SET NULL;


--
-- Name: parties parties_ar_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_ar_account_id_fkey FOREIGN KEY (ar_account_id) REFERENCES public.chartofaccounts(account_id) ON DELETE SET NULL;


--
-- Name: payments payments_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.chartofaccounts(account_id);


--
-- Name: payments payments_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


--
-- Name: payments payments_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


--
-- Name: purchaseinvoices purchaseinvoices_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseinvoices
    ADD CONSTRAINT purchaseinvoices_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


--
-- Name: purchaseinvoices purchaseinvoices_vendor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseinvoices
    ADD CONSTRAINT purchaseinvoices_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


--
-- Name: purchaseitems purchaseitems_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseitems
    ADD CONSTRAINT purchaseitems_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- Name: purchaseitems purchaseitems_purchase_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseitems
    ADD CONSTRAINT purchaseitems_purchase_invoice_id_fkey FOREIGN KEY (purchase_invoice_id) REFERENCES public.purchaseinvoices(purchase_invoice_id) ON DELETE CASCADE;


--
-- Name: purchasereturnitems purchasereturnitems_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturnitems
    ADD CONSTRAINT purchasereturnitems_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- Name: purchasereturnitems purchasereturnitems_purchase_return_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturnitems
    ADD CONSTRAINT purchasereturnitems_purchase_return_id_fkey FOREIGN KEY (purchase_return_id) REFERENCES public.purchasereturns(purchase_return_id) ON DELETE CASCADE;


--
-- Name: purchasereturns purchasereturns_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturns
    ADD CONSTRAINT purchasereturns_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


--
-- Name: purchasereturns purchasereturns_vendor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturns
    ADD CONSTRAINT purchasereturns_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


--
-- Name: purchaseunits purchaseunits_purchase_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseunits
    ADD CONSTRAINT purchaseunits_purchase_item_id_fkey FOREIGN KEY (purchase_item_id) REFERENCES public.purchaseitems(purchase_item_id) ON DELETE CASCADE;


--
-- Name: receipts receipts_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.chartofaccounts(account_id);


--
-- Name: receipts receipts_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


--
-- Name: receipts receipts_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


--
-- Name: salesinvoices salesinvoices_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesinvoices
    ADD CONSTRAINT salesinvoices_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


--
-- Name: salesinvoices salesinvoices_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesinvoices
    ADD CONSTRAINT salesinvoices_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


--
-- Name: salesitems salesitems_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesitems
    ADD CONSTRAINT salesitems_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- Name: salesitems salesitems_sales_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesitems
    ADD CONSTRAINT salesitems_sales_invoice_id_fkey FOREIGN KEY (sales_invoice_id) REFERENCES public.salesinvoices(sales_invoice_id) ON DELETE CASCADE;


--
-- Name: salesreturnitems salesreturnitems_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturnitems
    ADD CONSTRAINT salesreturnitems_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- Name: salesreturnitems salesreturnitems_sales_return_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturnitems
    ADD CONSTRAINT salesreturnitems_sales_return_id_fkey FOREIGN KEY (sales_return_id) REFERENCES public.salesreturns(sales_return_id) ON DELETE CASCADE;


--
-- Name: salesreturns salesreturns_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturns
    ADD CONSTRAINT salesreturns_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


--
-- Name: salesreturns salesreturns_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturns
    ADD CONSTRAINT salesreturns_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


--
-- Name: soldunits soldunits_sales_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.soldunits
    ADD CONSTRAINT soldunits_sales_item_id_fkey FOREIGN KEY (sales_item_id) REFERENCES public.salesitems(sales_item_id) ON DELETE CASCADE;


--
-- Name: soldunits soldunits_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.soldunits
    ADD CONSTRAINT soldunits_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.purchaseunits(unit_id) ON DELETE CASCADE;


--
-- Name: stockmovements stockmovements_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stockmovements
    ADD CONSTRAINT stockmovements_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- PostgreSQL database dump complete
--

\unrestrict 9Zd2NW5j6pFpC021EB3YkYOfLIDMucy1beDd1om2biOBwyNsgQXpOBAXohh7Km1

