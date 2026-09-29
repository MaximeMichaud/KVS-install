-- Synthetic rows; ktvs_tags_videos reproduces the KVS 7 reference definition.
-- Other tables cover AUTO_INCREMENT indexes which the native client must retain.
SET SESSION sql_mode = CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), 'NO_AUTO_VALUE_ON_ZERO');

CREATE TABLE ktvs_tags_videos (
    id INT(10) UNSIGNED NOT NULL AUTO_INCREMENT,
    tag_id INT(10) UNSIGNED NOT NULL,
    video_id INT(10) UNSIGNED NOT NULL,
    cr_dlist BIGINT(20) UNSIGNED NOT NULL DEFAULT 0,
    cr_ccount BIGINT(20) UNSIGNED NOT NULL DEFAULT 0,
    cr_cweight DECIMAL(20,4) UNSIGNED NOT NULL DEFAULT 0,
    cr_ctr DECIMAL(20,4) UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (tag_id, video_id),
    UNIQUE KEY id (id),
    KEY video_id (video_id),
    KEY cr_ctr (cr_ctr)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE ktvs_native_ai_primary_first (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id INT UNSIGNED NOT NULL,
    label VARCHAR(40) NOT NULL,
    PRIMARY KEY (id, tenant_id),
    KEY label_key (label)
) ENGINE=InnoDB;
CREATE TABLE ktvs_native_ai_primary_later (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id INT UNSIGNED NOT NULL,
    label VARCHAR(40) NOT NULL,
    PRIMARY KEY (tenant_id, id),
    KEY id_key (id),
    KEY label_key (label)
) ENGINE=InnoDB;
CREATE TABLE ktvs_native_ai_no_primary (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    label VARCHAR(40) NOT NULL,
    UNIQUE KEY id_key (id),
    KEY label_key (label)
) ENGINE=InnoDB;
CREATE TABLE ktvs_native_ai_secondary_composite (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id INT UNSIGNED NOT NULL,
    label VARCHAR(40) NOT NULL,
    PRIMARY KEY (tenant_id, label),
    KEY id_tenant (id, tenant_id)
) ENGINE=InnoDB;
CREATE TABLE ktvs_native_ai_generated (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id INT UNSIGNED NOT NULL,
    label VARCHAR(40) NOT NULL,
    quantity INT NOT NULL,
    tag_link INT UNSIGNED NOT NULL,
    doubled INT AS (quantity * 2) STORED,
    PRIMARY KEY (tenant_id, label),
    UNIQUE KEY id_key (id),
    KEY doubled_key (doubled),
    CONSTRAINT fk_native_generated_tag FOREIGN KEY (tag_link)
        REFERENCES ktvs_tags_videos (id) ON DELETE CASCADE
) ENGINE=InnoDB;
CREATE TABLE ktvs_native_ai_ordinary_child (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    tag_link INT UNSIGNED NOT NULL,
    label VARCHAR(40) NOT NULL,
    CONSTRAINT fk_native_ordinary_tag FOREIGN KEY (tag_link)
        REFERENCES ktvs_tags_videos (id) ON DELETE CASCADE
) ENGINE=InnoDB;
CREATE TABLE ktvs_native_ai_protected_child (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id INT UNSIGNED NOT NULL,
    child_link INT UNSIGNED NOT NULL,
    label VARCHAR(40) NOT NULL,
    PRIMARY KEY (group_id, child_link),
    UNIQUE KEY id_key (id),
    CONSTRAINT fk_native_protected_child FOREIGN KEY (child_link)
        REFERENCES ktvs_native_ai_ordinary_child (id) ON DELETE CASCADE
) ENGINE=InnoDB;

INSERT INTO ktvs_tags_videos VALUES
    (0,1,1,10,2,3.25,0.25), (7,1,2,20,4,6.50,0.50), (42,2,1,30,6,9.75,0.75);
INSERT INTO ktvs_native_ai_primary_first VALUES (0,10,'zero'), (7,11,'seven'), (42,12,'forty-two');
INSERT INTO ktvs_native_ai_primary_later VALUES (0,10,'zero'), (7,11,'seven'), (42,12,'forty-two');
INSERT INTO ktvs_native_ai_no_primary VALUES (0,'zero'), (7,'seven'), (42,'forty-two');
INSERT INTO ktvs_native_ai_secondary_composite VALUES (0,10,'zero'), (7,11,'seven'), (42,12,'forty-two');
INSERT INTO ktvs_native_ai_generated (id,tenant_id,label,quantity,tag_link) VALUES
    (0,10,'zero',3,0), (7,11,'seven',5,7), (42,12,'forty-two',9,42);
INSERT INTO ktvs_native_ai_ordinary_child VALUES (0,0,'zero'), (7,7,'seven'), (42,42,'forty-two');
INSERT INTO ktvs_native_ai_protected_child VALUES (0,10,0,'zero'), (7,11,7,'seven'), (42,12,42,'forty-two');

-- Preserve intentionally reserved identifiers, not merely MAX(id)+1.
ALTER TABLE ktvs_tags_videos AUTO_INCREMENT=1000;
ALTER TABLE ktvs_native_ai_primary_first AUTO_INCREMENT=1001;
ALTER TABLE ktvs_native_ai_primary_later AUTO_INCREMENT=1002;
ALTER TABLE ktvs_native_ai_no_primary AUTO_INCREMENT=1003;
ALTER TABLE ktvs_native_ai_secondary_composite AUTO_INCREMENT=1004;
ALTER TABLE ktvs_native_ai_generated AUTO_INCREMENT=1005;
ALTER TABLE ktvs_native_ai_ordinary_child AUTO_INCREMENT=1006;
ALTER TABLE ktvs_native_ai_protected_child AUTO_INCREMENT=1007;
