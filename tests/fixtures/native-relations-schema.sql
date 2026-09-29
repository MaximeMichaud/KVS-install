-- Independent synthetic arithmetic and referential-integrity fixtures.
CREATE TABLE ktvs_fixture_a (
    a_id INT NOT NULL PRIMARY KEY,
    x INT NOT NULL,
    doubled INT AS (x * 2) STORED,
    UNIQUE KEY pair_key (a_id, x),
    KEY doubled_key (doubled)
) ENGINE=InnoDB;
CREATE TABLE ktvs_fixture_b (
    b_id INT NOT NULL PRIMARY KEY,
    a_id INT DEFAULT NULL,
    a_x INT DEFAULT NULL,
    x INT NOT NULL,
    doubled INT AS (x * 2) VIRTUAL,
    KEY doubled_key (doubled),
    CONSTRAINT fk_fixture_pair FOREIGN KEY (a_id, a_x)
        REFERENCES ktvs_fixture_a (a_id, x)
        ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB;
CREATE TABLE ktvs_fixture_c (
    c_id INT NOT NULL PRIMARY KEY,
    b_id INT NOT NULL,
    parent_id INT DEFAULT NULL,
    CONSTRAINT fk_fixture_b FOREIGN KEY (b_id)
        REFERENCES ktvs_fixture_b (b_id) ON DELETE CASCADE,
    CONSTRAINT fk_fixture_self FOREIGN KEY (parent_id)
        REFERENCES ktvs_fixture_c (c_id) ON DELETE SET NULL
) ENGINE=InnoDB;

INSERT INTO ktvs_fixture_a (a_id,x) VALUES (1,3), (2,5);
INSERT INTO ktvs_fixture_b (b_id,a_id,a_x,x) VALUES
    (1,1,3,7), (2,2,5,11), (3,999,NULL,13), (4,NULL,999,17);
INSERT INTO ktvs_fixture_c VALUES (1,1,NULL), (2,2,1), (3,3,NULL);
