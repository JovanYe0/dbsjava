--
-- PostgreSQL database dump
--

-- Dumped from database version 16.2
-- Dumped by pg_dump version 16.2

-- Started on 2024-07-12 01:05:12

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
-- TOC entry 250 (class 1255 OID 16989)
-- Name: add_favourites(integer, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.add_favourites(IN p_product_id integer, IN p_member_id integer)
    LANGUAGE plpgsql
    AS $$DECLARE
    v_member_id INT;
    v_product_id INT;
    v_count INT;
BEGIN
    -- Check if the member exists
    SELECT id INTO v_member_id
    FROM member
    WHERE id = p_member_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Member with id % does not exist', p_member_id;
    END IF;

    -- Check if the product exists
    SELECT id INTO v_product_id
    FROM product
    WHERE id = p_product_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Product with id  does not exist';
    END IF;

    -- Check if the favourite already exists
    SELECT COUNT(*) INTO v_count
    FROM favourites
    WHERE product_id = v_product_id AND member_id = v_member_id;

    IF v_count > 0 THEN
        RAISE EXCEPTION 'Favourite for member id and product id already exists';
    END IF;

    -- Insert into favourites
    INSERT INTO favourites (product_id, member_id)
    VALUES (v_product_id, v_member_id);

    RAISE NOTICE 'Favourite added successfully for member id % and product id %', v_member_id, v_product_id;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION 'Data not found: %', SQLERRM;
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error: %', SQLERRM;
END;
$$;


--
-- TOC entry 242 (class 1255 OID 16956)
-- Name: compute_customer_lifetime_value(); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.compute_customer_lifetime_value()
    LANGUAGE plpgsql
    AS $$
DECLARE
    customer_id member.id%TYPE;
    total_orders INT := 0;
    total_spending DECIMAL(10, 2) := 0;
    customer_lifetime DECIMAL(10, 2);
    average_purchase_value DECIMAL(10, 2) := 0;
    retention_period INT DEFAULT 2;
    purchase_frequency DECIMAL(10, 2) := 0;
    clv_value DECIMAL(10, 2) := 0;
BEGIN
    FOR customer_id IN (SELECT id FROM member) LOOP
        -- Calculate total orders
        SELECT COUNT(so.id) INTO total_orders 
        FROM sale_order so
        JOIN sale_order_item soi ON so.id = soi.sale_order_id
        WHERE so.member_id = customer_id
        AND so.status = 'COMPLETED';

        -- Debug output: Total Orders
        RAISE NOTICE 'Customer ID: %, Total Orders: %', customer_id, total_orders;

        IF total_orders <= 1 THEN
            -- Set CLV to NULL if total orders are 1 or 0
            clv_value := NULL;
        ELSE
            -- Calculate customer lifetime in years
            SELECT COALESCE(DATE_PART('day', MAX(order_datetime) - MIN(order_datetime)) / 365.0, 0)
            INTO customer_lifetime
            FROM sale_order so
            WHERE so.member_id = customer_id
            AND so.status = 'COMPLETED';

            -- Debug output: Customer Lifetime
            RAISE NOTICE 'Customer ID: %, Customer Lifetime: % years', customer_id, customer_lifetime;

            -- Calculate total spending
            SELECT SUM(soi.quantity * p.unit_price) INTO total_spending
            FROM sale_order so
            JOIN sale_order_item soi ON so.id = soi.sale_order_id
            JOIN product p ON soi.product_id = p.id
            WHERE so.status = 'COMPLETED' AND so.member_id = customer_id;

            -- Calculate average purchase value
            average_purchase_value := COALESCE(total_spending, 0) / total_orders;

            -- Debug output: Average Purchase Value
            RAISE NOTICE 'Customer ID: %, Avg. Purchase Value: %, total spending:%', customer_id, average_purchase_value,total_spending;

            -- Calculate purchase frequency (orders per year)
            IF customer_lifetime > 0 THEN
                purchase_frequency := total_orders / customer_lifetime;
            ELSE
                purchase_frequency := 0;
            END IF;

            -- Debug output: Purchase Frequency
            RAISE NOTICE 'Customer ID: %, Purchase Frequency: % per year', customer_id, purchase_frequency;

            -- Calculate CLV
            clv_value := COALESCE(average_purchase_value, 0) * COALESCE(purchase_frequency, 0) * retention_period;
        END IF;

        -- Update CLV in member table
        UPDATE member
        SET clv = clv_value
        WHERE id = customer_id;

        -- Debug output: CLV Updated
        RAISE NOTICE 'Customer ID: %, CLV Updated: %', customer_id, clv_value;
		RAISE NOTICE 'avg_purchase: %',average_purchase_value;
    END LOOP;
END;
$$;


--
-- TOC entry 230 (class 1255 OID 16939)
-- Name: compute_running_total_spending(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.compute_running_total_spending() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Update running_total_spending for recently active members
    UPDATE member m
    SET running_total_spending = COALESCE((
        SELECT SUM(soi.quantity * p.unit_price) AS total_spending
        FROM sale_order so
        JOIN sale_order_item soi ON so.id = soi.sale_order_id
        JOIN product p ON soi.product_id = p.id
        WHERE so.status = 'COMPLETED' AND so.member_id = m.id
    ), 0)
    WHERE m.last_login_on >= NOW() - INTERVAL '6 months';

    -- Set running_total_spending to NULL for inactive members
    UPDATE member
    SET running_total_spending = NULL
    WHERE last_login_on < NOW() - INTERVAL '6 months';
END;
$$;


--
-- TOC entry 247 (class 1255 OID 16965)
-- Name: create_review(integer, integer, integer, text); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.create_review(IN p_member_id integer, IN p_product_id integer, IN p_rating integer, IN p_review_text text)
    LANGUAGE plpgsql
    AS $_$DECLARE
    v_order_id INT;
BEGIN
    -- Check if product_id is an integer
    IF p_product_id::text ~ '^[0-9]+$' THEN
        -- Check if the member has a completed order
        SELECT id INTO v_order_id
        FROM sale_order
        WHERE member_id = p_member_id
          AND status = 'COMPLETED'
        LIMIT 1;

        IF v_order_id IS NOT NULL THEN
            -- Check if the product is in the completed order
            PERFORM 1
            FROM sale_order_item
            WHERE sale_order_id = v_order_id
              AND product_id = p_product_id;

            IF FOUND THEN
                -- Check for duplicate rating and review
                PERFORM 1
                FROM reviews
                WHERE member_id = p_member_id
                  AND rating = p_rating
                  AND review_text = p_review_text;

                IF FOUND THEN
                    RAISE EXCEPTION 'Duplicate rating and review found.';
                ELSE
                    -- Insert the review
                    INSERT INTO reviews (member_id, product_id, rating, review_text)
                    VALUES (p_member_id, p_product_id, p_rating, p_review_text);
                    RAISE NOTICE 'Review inserted for member_id: %, product_id: %', p_member_id, p_product_id;
                END IF;
            ELSE
                RAISE EXCEPTION 'Product is not in the completed order.';
            END IF;
        ELSE
            RAISE EXCEPTION 'Member has no completed orders.';
        END IF;
    ELSE
        RAISE EXCEPTION 'Product ID is not an integer.';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error: %', SQLERRM;
END;
$_$;


--
-- TOC entry 249 (class 1255 OID 16992)
-- Name: delete_favourite(integer, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.delete_favourite(IN p_favourite_id integer, IN p_member_id integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM favourites
    WHERE favourite_id = p_favourite_id AND member_id = p_member_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'favourite with ID % for member % does not exist', p_favourite_id, p_member_id;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error: %', SQLERRM;
END $$;


--
-- TOC entry 246 (class 1255 OID 16934)
-- Name: delete_review(integer, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.delete_review(IN p_review_id integer, IN p_member_id integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM reviews 
    WHERE review_id = p_review_id 
    AND member_id = p_member_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Review with ID for member does not exist';
    END IF;
    
    -- Optional: Return a message or status if needed
    -- RETURN 'Review deleted successfully';
END;
$$;


--
-- TOC entry 248 (class 1255 OID 16963)
-- Name: get_age_group_spending(character, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_age_group_spending(p_gender character DEFAULT NULL::bpchar, p_min_total_spending numeric DEFAULT NULL::numeric, p_member_total_spending numeric DEFAULT NULL::numeric) RETURNS TABLE(age_group text, total_spending numeric, member_count integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH age_group_definitions AS (
        SELECT
            id AS member_id,
            gender,
            CASE
                WHEN DATE_PART('year', AGE(CURRENT_DATE, dob)) BETWEEN 18 AND 29 THEN '18-29'
                WHEN DATE_PART('year', AGE(CURRENT_DATE, dob)) BETWEEN 30 AND 39 THEN '30-39'
                WHEN DATE_PART('year', AGE(CURRENT_DATE, dob)) BETWEEN 40 AND 49 THEN '40-49'
                WHEN DATE_PART('year', AGE(CURRENT_DATE, dob)) BETWEEN 50 AND 59 THEN '50-59'
                ELSE '60+'
            END AS age_group
        FROM
            member
    ),
    member_spending AS (
        SELECT
            so.member_id,
            SUM(soi.quantity * p.unit_price) AS total_spending_per_member
        FROM
            sale_order so
        JOIN
            sale_order_item soi ON so.id = soi.sale_order_id
        JOIN
            product p ON soi.product_id = p.id
        GROUP BY
            so.member_id
    )
    SELECT
        agd.age_group,
        SUM(ms.total_spending_per_member) AS total_spending,
        CAST(COUNT(DISTINCT ms.member_id) AS INTEGER) AS member_count
    FROM
        member_spending ms
    JOIN
        age_group_definitions agd ON ms.member_id = agd.member_id
    WHERE
        (p_gender IS NULL OR agd.gender = p_gender)
    GROUP BY
        agd.age_group
    HAVING
        (p_min_total_spending IS NULL OR SUM(ms.total_spending_per_member) >= p_min_total_spending)
        AND (p_member_total_spending IS NULL OR AVG(ms.total_spending_per_member) >= p_member_total_spending);
END;
$$;


--
-- TOC entry 245 (class 1255 OID 16930)
-- Name: get_all_reviews(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_all_reviews(p_member_id integer) RETURNS TABLE(review_id integer, product_name character varying, rating integer, review_text text, date date)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Check if member has any reviews and return the results
    RETURN QUERY
    SELECT 
        r.review_id,
        p.name AS product_name,
        r.rating,
        r.review_text,
        r.date
    FROM reviews r
    JOIN product p ON r.product_id = p.id
    WHERE r.member_id = p_member_id
	ORDER BY r.review_id;
END;
$$;


--
-- TOC entry 252 (class 1255 OID 17010)
-- Name: get_fav(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_fav(p_member_id integer) RETURNS TABLE(favourite_id integer, name text, description text, unit_price numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY 
    SELECT 
        f.favourite_id,
        p.name::TEXT,          -- Explicit cast to TEXT
        p.description::TEXT,   -- Explicit cast to TEXT
        p.unit_price
    FROM 
        favourites f
    JOIN 
        product p ON f.product_id = p.id
    WHERE
        f.member_id = p_member_id;
END;
$$;


--
-- TOC entry 251 (class 1255 OID 17011)
-- Name: get_favourites_by_member(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_favourites_by_member(p_member_id integer) RETURNS TABLE(favourite_id integer, name text, description text, unit_price numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY 
    SELECT 
        f.favourite_id,
        p.name,
        p.description,
        p.unit_price
    FROM 
        favourites f
    JOIN 
        product p ON f.product_id = p.product_id
    WHERE
        f.member_id = p_member_id;
END;
$$;


--
-- TOC entry 243 (class 1255 OID 16957)
-- Name: get_reviews(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_reviews(p_reviews_id integer, p_member_id integer) RETURNS TABLE(review_id integer, product_name text, rating integer, review_text text, review_date date)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        r.review_id,
        p.name::TEXT AS product_name,  -- Explicitly cast to TEXT
        r.rating,
        r.review_text,
        r.date
    FROM reviews r
    JOIN product p ON r.product_id = p.id 
    WHERE r.member_id = p_member_id AND r.review_id = p_reviews_id;
END;
$$;


--
-- TOC entry 244 (class 1255 OID 16932)
-- Name: update_review(integer, integer, text, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.update_review(IN p_review_id integer, IN p_member_id integer, IN p_review_text text, IN p_rating integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_old_review_text TEXT;
    v_old_rating INT;
BEGIN
    -- Retrieve the current values from the reviews table
    SELECT review_text, rating
    INTO v_old_review_text, v_old_rating
    FROM reviews
    WHERE review_id = p_review_id AND member_id = p_member_id;
    
    -- Check if the new values are the same as the old values
    IF v_old_review_text = p_review_text AND
       v_old_rating = p_rating THEN
        -- Raise an exception if the values are the same
        RAISE EXCEPTION 'The new review text and rating are the same as the old values. The review cannot be updated.';
    ELSE
        -- Update the reviews table with the new values if they are different
        UPDATE reviews
        SET review_text = p_review_text,
            rating = p_rating
        WHERE review_id = p_review_id AND member_id = p_member_id;
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        -- Raise an exception if no review is found with the given review_id and member_id
        RAISE EXCEPTION 'No review found with the given review_id and member_id.';
END;
$$;


--
-- TOC entry 229 (class 1259 OID 16994)
-- Name: favourites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.favourites (
    favourite_id integer NOT NULL,
    product_id integer NOT NULL,
    member_id integer NOT NULL
);


--
-- TOC entry 228 (class 1259 OID 16993)
-- Name: favourites_favourite_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.favourites_favourite_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 4865 (class 0 OID 0)
-- Dependencies: 228
-- Name: favourites_favourite_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.favourites_favourite_id_seq OWNED BY public.favourites.favourite_id;


--
-- TOC entry 215 (class 1259 OID 16787)
-- Name: member; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.member (
    id integer NOT NULL,
    username character varying(50) NOT NULL,
    email character varying(50) NOT NULL,
    dob date NOT NULL,
    password character varying(255) NOT NULL,
    role integer NOT NULL,
    gender character(1) NOT NULL,
    last_login_on timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    clv numeric(10,3),
    running_total_spending numeric(10,3)
);


--
-- TOC entry 216 (class 1259 OID 16791)
-- Name: member_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.member_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 4866 (class 0 OID 0)
-- Dependencies: 216
-- Name: member_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.member_id_seq OWNED BY public.member.id;


--
-- TOC entry 217 (class 1259 OID 16792)
-- Name: member_role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.member_role (
    id integer NOT NULL,
    name character varying(25)
);


--
-- TOC entry 218 (class 1259 OID 16795)
-- Name: member_role_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.member_role_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 4867 (class 0 OID 0)
-- Dependencies: 218
-- Name: member_role_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.member_role_id_seq OWNED BY public.member_role.id;


--
-- TOC entry 219 (class 1259 OID 16796)
-- Name: product; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product (
    id integer NOT NULL,
    name character varying(255),
    description text,
    unit_price numeric NOT NULL,
    stock_quantity numeric DEFAULT 0 NOT NULL,
    country character varying(100),
    product_type character varying(50),
    image_url character varying(255) DEFAULT '/images/product.png'::character varying,
    manufactured_on timestamp without time zone
);


--
-- TOC entry 220 (class 1259 OID 16803)
-- Name: product_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 4868 (class 0 OID 0)
-- Dependencies: 220
-- Name: product_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_id_seq OWNED BY public.product.id;


--
-- TOC entry 226 (class 1259 OID 16893)
-- Name: reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reviews (
    review_id integer NOT NULL,
    member_id integer NOT NULL,
    product_id integer NOT NULL,
    review_text text,
    rating integer NOT NULL,
    date date DEFAULT CURRENT_DATE
);


--
-- TOC entry 225 (class 1259 OID 16892)
-- Name: reviews_review_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reviews_review_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 4869 (class 0 OID 0)
-- Dependencies: 225
-- Name: reviews_review_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reviews_review_id_seq OWNED BY public.reviews.review_id;


--
-- TOC entry 221 (class 1259 OID 16804)
-- Name: sale_order; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sale_order (
    id integer NOT NULL,
    member_id integer,
    order_datetime timestamp without time zone NOT NULL,
    status character varying(10)
);


--
-- TOC entry 222 (class 1259 OID 16807)
-- Name: sale_order_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sale_order_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 4870 (class 0 OID 0)
-- Dependencies: 222
-- Name: sale_order_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sale_order_id_seq OWNED BY public.sale_order.id;


--
-- TOC entry 223 (class 1259 OID 16808)
-- Name: sale_order_item; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sale_order_item (
    id integer NOT NULL,
    sale_order_id integer NOT NULL,
    product_id integer NOT NULL,
    quantity numeric NOT NULL
);


--
-- TOC entry 224 (class 1259 OID 16813)
-- Name: sale_order_item_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sale_order_item_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 4871 (class 0 OID 0)
-- Dependencies: 224
-- Name: sale_order_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sale_order_item_id_seq OWNED BY public.sale_order_item.id;


--
-- TOC entry 227 (class 1259 OID 16940)
-- Name: total_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.total_orders (
    count bigint
);


--
-- TOC entry 4690 (class 2604 OID 16997)
-- Name: favourites favourite_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.favourites ALTER COLUMN favourite_id SET DEFAULT nextval('public.favourites_favourite_id_seq'::regclass);


--
-- TOC entry 4680 (class 2604 OID 16814)
-- Name: member id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.member ALTER COLUMN id SET DEFAULT nextval('public.member_id_seq'::regclass);


--
-- TOC entry 4682 (class 2604 OID 16815)
-- Name: member_role id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.member_role ALTER COLUMN id SET DEFAULT nextval('public.member_role_id_seq'::regclass);


--
-- TOC entry 4683 (class 2604 OID 16816)
-- Name: product id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product ALTER COLUMN id SET DEFAULT nextval('public.product_id_seq'::regclass);


--
-- TOC entry 4688 (class 2604 OID 16896)
-- Name: reviews review_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews ALTER COLUMN review_id SET DEFAULT nextval('public.reviews_review_id_seq'::regclass);


--
-- TOC entry 4686 (class 2604 OID 16817)
-- Name: sale_order id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sale_order ALTER COLUMN id SET DEFAULT nextval('public.sale_order_id_seq'::regclass);


--
-- TOC entry 4687 (class 2604 OID 16818)
-- Name: sale_order_item id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sale_order_item ALTER COLUMN id SET DEFAULT nextval('public.sale_order_item_id_seq'::regclass);


--
-- TOC entry 4708 (class 2606 OID 16999)
-- Name: favourites favourites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.favourites
    ADD CONSTRAINT favourites_pkey PRIMARY KEY (favourite_id);


--
-- TOC entry 4692 (class 2606 OID 16820)
-- Name: member member_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.member
    ADD CONSTRAINT member_email_key UNIQUE (email);


--
-- TOC entry 4694 (class 2606 OID 16822)
-- Name: member member_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.member
    ADD CONSTRAINT member_pkey PRIMARY KEY (id);


--
-- TOC entry 4698 (class 2606 OID 16824)
-- Name: member_role member_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.member_role
    ADD CONSTRAINT member_role_pkey PRIMARY KEY (id);


--
-- TOC entry 4696 (class 2606 OID 16826)
-- Name: member member_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.member
    ADD CONSTRAINT member_username_key UNIQUE (username);


--
-- TOC entry 4700 (class 2606 OID 16828)
-- Name: product product_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product
    ADD CONSTRAINT product_pkey PRIMARY KEY (id);


--
-- TOC entry 4706 (class 2606 OID 16902)
-- Name: reviews reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_pkey PRIMARY KEY (review_id);


--
-- TOC entry 4704 (class 2606 OID 16830)
-- Name: sale_order_item sale_order_item_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sale_order_item
    ADD CONSTRAINT sale_order_item_pkey PRIMARY KEY (id);


--
-- TOC entry 4702 (class 2606 OID 16832)
-- Name: sale_order sale_order_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sale_order
    ADD CONSTRAINT sale_order_pkey PRIMARY KEY (id);


--
-- TOC entry 4715 (class 2606 OID 17005)
-- Name: favourites favourites_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.favourites
    ADD CONSTRAINT favourites_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id);


--
-- TOC entry 4716 (class 2606 OID 17000)
-- Name: favourites favourites_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.favourites
    ADD CONSTRAINT favourites_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.product(id);


--
-- TOC entry 4709 (class 2606 OID 16833)
-- Name: member fk_member_role_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.member
    ADD CONSTRAINT fk_member_role_id FOREIGN KEY (role) REFERENCES public.member_role(id);


--
-- TOC entry 4711 (class 2606 OID 16838)
-- Name: sale_order_item fk_sale_order_item_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sale_order_item
    ADD CONSTRAINT fk_sale_order_item_product FOREIGN KEY (product_id) REFERENCES public.product(id);


--
-- TOC entry 4712 (class 2606 OID 16843)
-- Name: sale_order_item fk_sale_order_item_sale_order; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sale_order_item
    ADD CONSTRAINT fk_sale_order_item_sale_order FOREIGN KEY (sale_order_id) REFERENCES public.sale_order(id);


--
-- TOC entry 4710 (class 2606 OID 16848)
-- Name: sale_order fk_sale_order_member; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sale_order
    ADD CONSTRAINT fk_sale_order_member FOREIGN KEY (member_id) REFERENCES public.member(id);


--
-- TOC entry 4713 (class 2606 OID 16903)
-- Name: reviews reviews_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.member(id);


--
-- TOC entry 4714 (class 2606 OID 16908)
-- Name: reviews reviews_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.product(id);


-- Completed on 2024-07-12 01:05:12

--
-- PostgreSQL database dump complete
--

