--
-- Table structure for table `domains`
-- (domains we host, along with nameserver records)
--

DROP TABLE IF EXISTS `domains`;
CREATE TABLE `domains` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `owner` int(11) NOT NULL DEFAULT 0,
  `zone` varchar(255) NOT NULL DEFAULT '',
  `ns` varchar(255) NOT NULL DEFAULT '',
  `src` varchar(255) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`)
);

--
-- Table structure for table `ssh_keys` (per-user auth)
--

DROP TABLE IF EXISTS `ssh_keys`;
CREATE TABLE `ssh_keys` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `owner` int(11) NOT NULL DEFAULT 0,
  `key_text` mediumtext NOT NULL DEFAULT '',
  `fingerprint` varchar(256) DEFAULT '',
  PRIMARY KEY (`id`)
);

--
-- Table structure for table `users` (users with accounts)
--

DROP TABLE IF EXISTS `users`;
CREATE TABLE `users` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `login` varchar(25) NOT NULL DEFAULT '',
  `password` varchar(42) NOT NULL DEFAULT '',
  `email` varchar(80) NOT NULL DEFAULT '',
  `ip` varchar(30) NOT NULL DEFAULT '',
  `stripe_token` varchar(50) NOT NULL DEFAULT '',
  `created` timestamp NOT NULL DEFAULT current_timestamp(),
  `ssh_key` mediumtext NOT NULL DEFAULT '',
  `hook_notification` tinyint(4) DEFAULT 0,
  `status` enum('trial','banned','sponsored','expired','paid') DEFAULT 'trial',
  `hash` varchar(100) DEFAULT NULL,
  `legacy` tinyint(1) DEFAULT 0,
  `stripe_customer` varchar(50) DEFAULT '',
  PRIMARY KEY (`id`)
) ;

--
-- Table structure for table `webhooks` (logs)
--

DROP TABLE IF EXISTS `webhooks`;
CREATE TABLE `webhooks` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `owner` int(11) NOT NULL DEFAULT 0,
  `event_id` varchar(80) NOT NULL DEFAULT '',
  `created` timestamp NOT NULL DEFAULT current_timestamp(),
  `text` text DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `owner` (`owner`,`event_id`)
);

